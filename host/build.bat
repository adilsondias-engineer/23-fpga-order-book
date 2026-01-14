@echo off
REM Build BBO receiver for Windows
REM Requires Visual Studio command prompt or cl.exe in PATH

echo Building bbo_receiver.exe...
cl /O2 /W3 bbo_receiver.c /Fe:bbo_receiver.exe setupapi.lib

if %ERRORLEVEL% EQU 0 (
    echo Build successful!
    echo.
    echo Usage: bbo_receiver.exe [count]
    echo   count = number of BBO packets to receive (default: 10)
) else (
    echo Build failed! Make sure Visual Studio is installed and run from VS command prompt.
)
