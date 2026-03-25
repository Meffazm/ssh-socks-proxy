@echo off
:: Launch Discord routed through the SOCKS5 proxy
:: Finds the latest Discord.exe and passes --proxy-server directly

for /f "usebackq tokens=1,* delims==" %%a in ("%~dp0.env") do (
    if "%%a"=="SOCKS_PORT" set SOCKS_PORT=%%b
)

if "%SOCKS_PORT%"=="" set SOCKS_PORT=8090

:: Find the latest app-* directory under Discord
set DISCORD_DIR=%LOCALAPPDATA%\Discord
set DISCORD_EXE=
for /f "delims=" %%d in ('dir /b /ad /o-n "%DISCORD_DIR%\app-*" 2^>nul') do (
    if not defined DISCORD_EXE set DISCORD_EXE=%DISCORD_DIR%\%%d\Discord.exe
)

if not defined DISCORD_EXE (
    echo Error: Discord.exe not found in %DISCORD_DIR%
    pause
    exit /b 1
)

start "" "%DISCORD_EXE%" --proxy-server="socks5://127.0.0.1:%SOCKS_PORT%"
