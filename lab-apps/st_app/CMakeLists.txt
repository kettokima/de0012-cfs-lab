project(CFE_ST_APP C)
set(APP_SRC_FILES
    fsw/src/st_app.c
)

# Register as an app named "st_app", module files will end up in cf/st_app.so
add_cfe_app(st_app ${APP_SRC_FILES})
