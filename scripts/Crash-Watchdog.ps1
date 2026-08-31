# Crash-Watchdog.ps1 - Windows 死机取证 + 关键事件告警
# 作用：
#   1. 检测蓝屏/崩溃关键事件（Kernel-Power 41 / BugCheck 1001 / WHEA 18,19），触发即 QQ 邮件告警
#   2. 收集崩溃证据：蓝屏 dump、事件日志、系统信息，归档到 C:\monitoring\evidence\
#   3. 轮询 Prometheus /api/v1/alerts，把触发的阈值告警转成 QQ 邮件
# 部署：由计划任务每 5 分钟运行（见 deploy.ps1）

$ErrorActionPreference = "SilentlyContinue"
$Base   = "C:\monitoring"
$Evid   = Join-Path $Base "evidence"
$State  = Join-Path $Base "state"
$Mailer = Join-Path $Base "scripts\Send-QQMail.ps1"
$LogFile = Join-Path $Base "logs\watchdog.log"
New-Item -ItemType Directory -Force -Path $Evid, $State, (Split-Path $LogFile) | Out-Null

# 写日志（无 BOM UTF-8 追加，避免中文乱码）
function Write-Log([string]$Level, [string]$Msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg"
    [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- 1. 关键崩溃事件检测（去重靠 state 里记最后处理的事件时间） ----------
$StateFile = Join-Path $State "last-crash-check.txt"
$Since = Get-Date -Date (Get-Content $StateFile -Raw -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue
if (-not $Since) { $Since = (Get-Date).AddMinutes(-6) }
$Now = Get-Date

$crashFilter = @{
    LogName   = "System"
    StartTime = $Since
    EndTime   = $Now
}
$crashIds  = 41, 1001, 1000, 6008          # Kernel-Power / BugCheck / app crash / unexpected shutdown
$crashEvts = Get-WinEvent -FilterHashtable $crashFilter |
             Where-Object { $crashIds -contains $_.Id }

# WHEA 硬件错误（CPU/内存/PCIe），在 Microsoft-Windows-WHEA-Logger 日志里
$wheaEvts  = Get-WinEvent -LogName "Microsoft-Windows-WHEA-Logger/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
             Where-Object { $_.TimeCreated -ge $Since -and ($_.Id -in 17,18,19,20) }

if ($crashEvts -or $wheaEvts) {
    # 收集证据
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $dumpDir = "$Evid\crash-$ts"
    New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null
    Write-Log "WARN" "检测到崩溃事件: 蓝屏/异常关机 $($crashEvts.Count) 条, WHEA $($wheaEvts.Count) 条, 证据目录 $dumpDir"

    $crashEvts | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
        Out-File "$dumpDir\events.txt" -Encoding utf8
    $wheaEvts  | Select-Object TimeCreated, Id, LevelDisplayName, Message |
        Out-File "$dumpDir\whea.txt" -Encoding utf8

    # 复制蓝屏 minidump（若有新生成的）
    Copy-Item "C:\Windows\Minidump\*.dmp" $dumpDir -ErrorAction SilentlyContinue

    # 系统信息快照
    systeminfo > "$dumpDir\systeminfo.txt" 2>&1
    Get-Process | Sort-Object -Descending WorkingSet64 | Select-Object -First 20 Name, Id, @{N="MemMB";E={[math]::Round($_.WorkingSet64/1MB)}} |
        Out-File "$dumpDir\top-mem.txt" -Encoding utf8

    # 告警邮件
    $body = @"
检测到崩溃/关键错误事件
时间: $ts
蓝屏/异常关机事件: $($crashEvts.Count) 条
WHEA 硬件错误: $($wheaEvts.Count) 条
证据目录: $dumpDir
"@
    & $Mailer -Subject "[崩溃告警] $env:COMPUTERNAME" -Body $body
}

# 记录本次检查时间
$Now.ToString("o") | Set-Content $StateFile

# ---------- 2. Prometheus 阈值告警 → 邮件（去重） ----------
$promHost = "http://localhost:1000"
$alertStateFile = Join-Path $State "last-alerts.json"

try {
    # 用 Invoke-WebRequest 手动 UTF-8 解码：PS 5.1 的 Invoke-RestMethod 在响应
    # 无 charset=utf-8 时会按 Latin-1 解码，导致中文告警乱码
    $resp = Invoke-WebRequest -Uri "$promHost/api/v1/alerts" -TimeoutSec 10 -UseBasicParsing
    $alerts = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    $firing = $alerts.data.alerts | Where-Object { $_.state -eq "firing" }
    
    if ($firing) {
        # 加载已发送的告警指纹（避免重复发邮件）
        $sentFingerprints = @{}
        if (Test-Path $alertStateFile) {
            $prev = Get-Content $alertStateFile -Raw | ConvertFrom-Json
            foreach ($fp in $prev.fingerprints) { $sentFingerprints[$fp] = $true }
        }
        
        # 筛选新告警（用 labels 组合作为指纹，Prometheus v3 alerts API 无 fingerprint 字段）
        $newAlerts = @()
        $currentFingerprints = @()
        foreach ($a in $firing) {
            $fp = ($a.labels | ConvertTo-Json -Compress)
            $currentFingerprints += $fp
            if (-not $sentFingerprints.ContainsKey($fp)) {
                $newAlerts += $a
            }
        }
        
        # 发送新告警邮件
        if ($newAlerts) {
            $lines = foreach ($a in $newAlerts) {
                $n = $a.labels.alertname
                $s = $a.annotations.summary
                $v = $a.labels.severity
                "$n [$v]: $s"
            }
            $body2 = "以下阈值告警新触发:`n`n" + ($lines -join "`n") + "`n`n触发时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            & $Mailer -Subject "[阈值告警] $env:COMPUTERNAME ($($newAlerts.Count) 条新增)" -Body $body2
            Write-Log "WARN" "发送阈值告警 $($newAlerts.Count) 条: $($lines -join ' | ')"
        }
        
        # 持久化当前 firing 告警指纹
        @{ fingerprints = $currentFingerprints; updated = (Get-Date).ToString("o") } |
            ConvertTo-Json | Set-Content $alertStateFile
    } else {
        # 无告警时清空状态（避免已恢复的告警再次触发时被误判为旧告警）
        if (Test-Path $alertStateFile) { Remove-Item $alertStateFile }
    }
} catch {
    # Prometheus 未启动或不可达，忽略
}
