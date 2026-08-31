# Start-Prometheus.ps1 - 启动 Prometheus（由计划任务调用）
# Prometheus 是纯控制台程序，不含 Windows 服务集成，
# 因此用计划任务 + 本脚本实现开机自启与崩溃拉起。
param(
    [string]$InstallPath = "C:\monitoring"
)

$promExe    = "$InstallPath\bin\prometheus.exe"
$promConfig = "$InstallPath\prometheus\prometheus.yml"
$promData   = "$InstallPath\prometheus\data"
$logDir     = "$InstallPath\logs"
$pidFile    = "$InstallPath\state\prometheus.pid"

# 确保目录存在
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not (Test-Path (Split-Path $pidFile))) { New-Item -ItemType Directory -Path (Split-Path $pidFile) -Force | Out-Null }

# 若已在运行则退出（防止重复启动）
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -like "*prometheus*") {
            exit 0
        }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# 启动 Prometheus，日志重定向到文件
$args = @(
    "--config.file=`"$promConfig`"",
    "--storage.tsdb.path=`"$promData`"",
    "--web.listen-address=:1000"
)

$proc = Start-Process -FilePath $promExe -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput "$logDir\prometheus.log" -RedirectStandardError "$logDir\prometheus.err.log"

# 记录 PID
Set-Content -Path $pidFile -Value $proc.Id

# 等待进程退出（计划任务可设置为无限期运行）
$proc.WaitForExit()

# 进程退出后清理 PID 文件
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
