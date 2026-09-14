@echo off
REM TVBox Android daily line validation
REM Scheduled by Windows Task Scheduler
REM Runs daily at 20:30

cd /d "C:\projects\tvbox-config"

REM Kill zombie tail/grep processes that may hold log file open
taskkill /F /IM tail.exe >nul 2>&1
taskkill /F /IM grep.exe >nul 2>&1

REM Also kill zombie adb/MuMu processes that may hold log file open
taskkill /F /IM adb.exe >nul 2>&1
taskkill /F /IM MuMuPlayer.exe >nul 2>&1
taskkill /F /IM MuMuVMMHeadless.exe >nul 2>&1

echo =================================================
echo   TVBox Daily Line Validation - %date% %time%
echo =================================================

REM Record log file timestamp before running PowerShell
for %%F in (".\android-daily-validation.log") do set BEFORE_SIZE=%%~zF

powershell -ExecutionPolicy Bypass -File ".\android-line-validation.ps1" -NotificationSuffix "_daily" >> ".\android-daily-validation.log" 2>&1
set PS_EXIT=%ERRORLEVEL%

REM Verify PowerShell actually wrote to the log
for %%F in (".\android-daily-validation.log") do set AFTER_SIZE=%%~zF
if "%BEFORE_SIZE%"=="%AFTER_SIZE%" (
    echo [WARNING] Log file unchanged - PowerShell may not have executed
    echo   Possible cause: log file locked by another process
    echo   Check for zombie processes holding the file handle
)

REM Trigger worker to flush notifications immediately
"C:\Program Files\nodejs\node.exe" "C:\claude workspace\video_queue_worker.js" >> "C:\claude workspace\.video-queue\worker.log" 2>&1

echo.
echo ================================================
echo   Daily validation complete. (ps exit=%PS_EXIT%)
echo ================================================