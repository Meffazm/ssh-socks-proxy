@echo off
:: Launch Discord routed through the HTTP proxy
:: Requires HTTP_PORT to be set in .env and pproxy running

for /f "usebackq tokens=1,* delims==" %%a in ("%~dp0.env") do (
    if "%%a"=="HTTP_PORT" set HTTP_PORT=%%b
)

if "%HTTP_PORT%"=="" (
    echo Error: HTTP_PORT not set in .env
    pause
    exit /b 1
)

set HTTPS_PROXY=http://127.0.0.1:%HTTP_PORT%
set HTTP_PROXY=http://127.0.0.1:%HTTP_PORT%
start "" "%LOCALAPPDATA%\Discord\Update.exe" --processStart Discord.exe
