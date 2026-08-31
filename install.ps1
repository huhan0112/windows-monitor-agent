#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows Server Monitor - One-Click Installation
.DESCRIPTION
    Auto install windows_exporter and Prometheus services
.NOTES
    Requires Administrator privileges
#>

param(
    [string]$InstallPath = "C:\monitoring",
    [string]$ToEmail = ""
)

$ErrorActionPreference = "Stop"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Windows Server Monitor - Installation" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# 1. Check admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Administrator privileges required" -ForegroundColor Red
    exit 1
}

Write-Host "`n[1/7] Checking prerequisites..." -ForegroundColor Yellow

# Check ports (忽略本组件自身已占用的端口，支持重复运行)
$portsToCheck = @(9182, 9090)
foreach ($port in $portsToCheck) {
    $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        $ownProcess = $false
        # 9182 = windows_exporter，9090 = prometheus，若占用进程是它们自己则跳过
        foreach ($conn in $listener) {
            $procName = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            if ($port -eq 9182 -and $procName -eq "windows_exporter") { $ownProcess = $true }
            if ($port -eq 9090 -and $procName -eq "prometheus") { $ownProcess = $true }
        }
        if ($ownProcess) {
            Write-Host "  INFO: Port $port used by existing component (will be re-installed)" -ForegroundColor Gray
        } else {
            Write-Host "  ERROR: Port $port already in use by other process" -ForegroundColor Red
            exit 1
        }
    }
}
Write-Host "  OK: Port check passed" -ForegroundColor Green

# 2. Create directories
Write-Host "`n[2/7] Creating directory structure..." -ForegroundColor Yellow
$dirs = @(
    $InstallPath,
    "$InstallPath\bin",
    "$InstallPath\config",
    "$InstallPath\prometheus",
    "$InstallPath\prometheus\rules",
    "$InstallPath\prometheus\data",
    "$InstallPath\scripts",
    "$InstallPath\state",
    "$InstallPath\logs"
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
Write-Host "  OK: Directories created" -ForegroundColor Green

# 2.5. 停止旧服务（防止二进制文件被占用无法覆盖）
Write-Host "`n[2.5/7] Stopping existing services..." -ForegroundColor Yellow
$exporterService = Get-Service -Name "windows_exporter" -ErrorAction SilentlyContinue
if ($exporterService) {
    Write-Host "  Stopping windows_exporter..." -ForegroundColor Gray
    Stop-Service -Name "windows_exporter" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
# 停止旧 prometheus 进程（若有）
$promPidFile = "$InstallPath\state\prometheus.pid"
if (Test-Path $promPidFile) {
    $oldPromPid = Get-Content $promPidFile -ErrorAction SilentlyContinue
    if ($oldPromPid) {
        Stop-Process -Id $oldPromPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}
Get-Process -Name "prometheus" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "  OK: Existing services stopped" -ForegroundColor Green

# 3. Copy files
Write-Host "`n[3/7] Copying program files..." -ForegroundColor Yellow
$scriptDir = $PSScriptRoot

Copy-Item "$scriptDir\bin\windows_exporter.exe" "$InstallPath\bin\" -Force
Copy-Item "$scriptDir\bin\prometheus.exe" "$InstallPath\bin\" -Force
Copy-Item "$scriptDir\bin\promtool.exe" "$InstallPath\bin\" -Force
Write-Host "  OK: Binaries copied" -ForegroundColor Green

Copy-Item "$scriptDir\config\windows_exporter.yaml" "$InstallPath\config\" -Force
Copy-Item "$scriptDir\prometheus\prometheus.yml" "$InstallPath\prometheus\" -Force
Copy-Item "$scriptDir\prometheus\rules\alert_rules.yml" "$InstallPath\prometheus\rules\" -Force
Write-Host "  OK: Config files copied" -ForegroundColor Green

Copy-Item "$scriptDir\scripts\*" "$InstallPath\scripts\" -Force
Write-Host "  OK: Scripts copied" -ForegroundColor Green

# 4. Configure SMTP
Write-Host "`n[4/7] Configuring email notifications..." -ForegroundColor Yellow
$smtpConfigPath = "$InstallPath\config\smtp.conf"
if (Test-Path "$scriptDir\config\smtp.conf") {
    # 始终复制 smtp.conf 模板
    Copy-Item "$scriptDir\config\smtp.conf" $smtpConfigPath -Force

    # 若指定了收件邮箱则覆盖 TO_ADDRESS
    if ($ToEmail) {
        $content = Get-Content $smtpConfigPath -Raw
        $content = $content -replace 'TO_ADDRESS=.*', "TO_ADDRESS=$ToEmail"
        Set-Content -Path $smtpConfigPath -Value $content -NoNewline
    }

    # 设置文件权限：仅 SYSTEM 和 Administrators 可读写
    $acl = Get-Acl $smtpConfigPath
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "Allow")))
    Set-Acl -Path $smtpConfigPath -AclObject $acl

    if ($ToEmail) {
        Write-Host "  OK: SMTP configured (To: $ToEmail)" -ForegroundColor Green
    } else {
        Write-Host "  OK: SMTP config copied (To: $(Select-String -Path $smtpConfigPath -Pattern '^TO_ADDRESS=' | ForEach-Object { $_.Line -replace 'TO_ADDRESS=','' }))" -ForegroundColor Green
        Write-Host "    如需修改收件邮箱，编辑 $smtpConfigPath 或重跑加 -ToEmail 参数" -ForegroundColor Gray
    }
} else {
    Write-Host "  WARNING: smtp.conf template not found" -ForegroundColor Yellow
}

# 5. Install windows_exporter service
Write-Host "`n[5/7] Installing windows_exporter service..." -ForegroundColor Yellow
$exporterService = Get-Service -Name "windows_exporter" -ErrorAction SilentlyContinue
if ($exporterService) {
    Write-Host "  Service exists, stopping..." -ForegroundColor Gray
    Stop-Service -Name "windows_exporter" -Force
    Start-Sleep -Seconds 2
    & sc.exe delete "windows_exporter" | Out-Null
    Start-Sleep -Seconds 1
}

# v0.31.8 已移除 install 子命令，改用 sc.exe 注册
$weExe = "$InstallPath\bin\windows_exporter.exe"
$weConfig = "$InstallPath\config\windows_exporter.yaml"
$weLog = "$InstallPath\logs\exporter.log"
$weBinPath = "`"$weExe`" --config.file=`"$weConfig`" --log.file=`"$weLog`""

& sc.exe create windows_exporter binPath= $weBinPath start= auto DisplayName= "Windows Exporter" | Out-Null

if ($?) {
    Start-Service -Name "windows_exporter"
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name "windows_exporter"
    if ($svc.Status -eq "Running") {
        Write-Host "  OK: windows_exporter service running" -ForegroundColor Green
    } else {
        Write-Host "  ERROR: Service failed to start" -ForegroundColor Red
        Write-Host "    Check: sc.exe qc windows_exporter ; type C:\monitoring\logs\exporter.log" -ForegroundColor Gray
        exit 1
    }
} else {
    Write-Host "  ERROR: Service installation failed" -ForegroundColor Red
    exit 1
}

# 6. Install Prometheus (scheduled task, auto-start on boot)
# Prometheus 是纯控制台程序，不含 Windows 服务集成，用计划任务实现开机自启
Write-Host "`n[6/7] Installing Prometheus auto-start task..." -ForegroundColor Yellow

# 清理旧的失败服务（如果存在）
$promService = Get-Service -Name "prometheus" -ErrorAction SilentlyContinue
if ($promService) {
    Write-Host "  Removing old prometheus service..." -ForegroundColor Gray
    $cimSvc = Get-CimInstance Win32_Service -Filter "Name='prometheus'" -ErrorAction SilentlyContinue
    if ($cimSvc) { Invoke-CimMethod -InputObject $cimSvc -MethodName Delete | Out-Null }
    Start-Sleep -Seconds 1
}

# 清理旧的同名计划任务
$promTaskName = "WindowsMonitor-Prometheus"
$existingPromTask = Get-ScheduledTask -TaskName $promTaskName -ErrorAction SilentlyContinue
if ($existingPromTask) {
    Unregister-ScheduledTask -TaskName $promTaskName -Confirm:$false
}

$startPromScript = "$InstallPath\scripts\Start-Prometheus.ps1"
$promAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startPromScript`" -InstallPath `"$InstallPath`""
$promTrigger = New-ScheduledTaskTrigger -AtStartup
$promPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$promSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $promTaskName -Action $promAction -Trigger $promTrigger -Principal $promPrincipal -Settings $promSettings -Description "Prometheus Monitoring (auto-start)" | Out-Null

$promTask = Get-ScheduledTask -TaskName $promTaskName -ErrorAction SilentlyContinue
if ($promTask) {
    # 立即启动一次
    Start-ScheduledTask -TaskName $promTaskName
    Write-Host "  OK: Prometheus auto-start task created and started" -ForegroundColor Green
} else {
    Write-Host "  ERROR: Prometheus task creation failed" -ForegroundColor Red
    exit 1
}

# 7. Configure scheduled task
Write-Host "`n[7/7] Configuring crash watchdog task..." -ForegroundColor Yellow
$taskName = "WindowsMonitor-CrashWatchdog"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$watchdogScript = "$InstallPath\scripts\Crash-Watchdog.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$watchdogScript`""
# RepetitionDuration 用 10 年代替 MaxValue（任务计划程序上限约 P99999DT23H59M59S，MaxValue 超范围会报错）
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Windows Crash Monitor and Alert" | Out-Null

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "  OK: Scheduled task created" -ForegroundColor Green
} else {
    Write-Host "  ERROR: Task creation failed" -ForegroundColor Red
    exit 1
}

# 8. Verification
Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host "  Installation Verification" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

Write-Host "`nService Status:" -ForegroundColor Yellow
$svc = Get-Service -Name "windows_exporter" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  OK: windows_exporter is running" -ForegroundColor Green
} else {
    Write-Host "  ERROR: windows_exporter is not running" -ForegroundColor Red
}

Write-Host "`nScheduled Tasks:" -ForegroundColor Yellow
$promTask = Get-ScheduledTask -TaskName "WindowsMonitor-Prometheus" -ErrorAction SilentlyContinue
if ($promTask) {
    Write-Host "  OK: WindowsMonitor-Prometheus ($($promTask.State))" -ForegroundColor Green
} else {
    Write-Host "  ERROR: WindowsMonitor-Prometheus missing" -ForegroundColor Red
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and $task.State -eq "Ready") {
    Write-Host "  OK: $taskName is ready" -ForegroundColor Green
} else {
    Write-Host "  ERROR: $taskName status abnormal" -ForegroundColor Red
}

Write-Host "`nEndpoint Test:" -ForegroundColor Yellow
Start-Sleep -Seconds 3
try {
    $response = Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing -TimeoutSec 5
    if ($response.StatusCode -eq 200) {
        Write-Host "  OK: windows_exporter (http://localhost:9182) accessible" -ForegroundColor Green
    }
} catch {
    Write-Host "  ERROR: windows_exporter endpoint unreachable" -ForegroundColor Red
}

try {
    $response = Invoke-WebRequest -Uri "http://localhost:9090/-/healthy" -UseBasicParsing -TimeoutSec 5
    if ($response.StatusCode -eq 200) {
        Write-Host "  OK: Prometheus (http://localhost:9090) accessible" -ForegroundColor Green
    }
} catch {
    Write-Host "  ERROR: Prometheus endpoint unreachable" -ForegroundColor Red
}

Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Cyan

Write-Host "`nAccess URLs:" -ForegroundColor Yellow
Write-Host "  Prometheus Web UI : http://localhost:9090" -ForegroundColor White
Write-Host "  Metrics Endpoint  : http://localhost:9182/metrics" -ForegroundColor White

Write-Host "`nConfiguration Files:" -ForegroundColor Yellow
Write-Host "  windows_exporter  : $InstallPath\config\windows_exporter.yaml" -ForegroundColor White
Write-Host "  Prometheus        : $InstallPath\prometheus\prometheus.yml" -ForegroundColor White
Write-Host "  Alert Rules       : $InstallPath\prometheus\rules\alert_rules.yml" -ForegroundColor White
Write-Host "  SMTP Config       : $InstallPath\config\smtp.conf" -ForegroundColor White

if (-not $ToEmail) {
    Write-Host "`nIMPORTANT:" -ForegroundColor Yellow
    Write-Host "  Please edit $InstallPath\config\smtp.conf to configure email alerts" -ForegroundColor White
}

Write-Host "`nLog Files:" -ForegroundColor Yellow
Write-Host "  windows_exporter  : $InstallPath\logs\exporter.log" -ForegroundColor White
Write-Host "  Crash Watchdog    : $InstallPath\logs\watchdog.log" -ForegroundColor White
Write-Host "  Alert State       : $InstallPath\state\last-alerts.json" -ForegroundColor White

Write-Host ""

