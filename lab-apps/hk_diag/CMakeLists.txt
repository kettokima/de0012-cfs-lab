project(CFE_HK_DIAG_APP C)
set(APP_SRC_FILES
    fsw/src/hk_diag.c
)
add_cfe_app(hk_diag ${APP_SRC_FILES})
