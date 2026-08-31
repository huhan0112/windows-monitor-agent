# Send-QQMail.ps1 - QQ 邮箱 SMTP 通知（PowerShell）
# 用法: powershell -File Send-QQMail.ps1 -Subject "标题" -Body "正文"
# 依赖内置 .NET，无需额外安装。
# 配置文件：C:\monitoring\config\smtp.conf（或通过环境变量 SMTP_CONFIG_FILE 指定）

param(
    [Parameter(Mandatory=$true)][string]$Subject,
    [Parameter(Mandatory=$true)][string]$Body,
    [string]$ToAddress = ""
)

$ErrorActionPreference = "Stop"

# 读取配置文件
$ConfigFile = $env:SMTP_CONFIG_FILE
if (-not $ConfigFile) { $ConfigFile = "C:\monitoring\config\smtp.conf" }

if (-not (Test-Path $ConfigFile)) {
    Write-Output "ERROR: SMTP 配置文件不存在: $ConfigFile"
    exit 1
}

$config = @{}
Get-Content $ConfigFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    $config[$k.Trim()] = $v.Trim()
}

$SmtpHost   = $config['SMTP_HOST']
$SmtpPort   = [int]$config['SMTP_PORT']
$Username   = $config['SMTP_USERNAME']
$AuthCode   = $config['SMTP_AUTH_CODE']
$FromAddr   = $config['FROM_ADDRESS']
$ToAddr     = $config['TO_ADDRESS']

# 若指定了 -ToAddress 参数则覆盖收件人
if ($ToAddress) { $ToAddr = $ToAddress }

# 验证必填字段
if (-not ($SmtpHost -and $SmtpPort -and $Username -and $AuthCode -and $FromAddr -and $ToAddr)) {
    Write-Output "ERROR: SMTP 配置不完整，请检查 $ConfigFile"
    exit 1
}

$msg = New-Object System.Net.Mail.MailMessage
$msg.From = $FromAddr
$msg.To.Add($ToAddr)
$msg.Subject = $Subject
$msg.Body = $Body
$msg.BodyEncoding = [System.Text.Encoding]::UTF8
$msg.SubjectEncoding = [System.Text.Encoding]::UTF8
$msg.IsBodyHtml = $false

$client = New-Object System.Net.Mail.SmtpClient($SmtpHost, $SmtpPort)
$client.EnableSsl = $true
$client.Credentials = New-Object System.Net.NetworkCredential($Username, $AuthCode)

try {
    $client.Send($msg)
    Write-Output "SENT OK: $Subject"
} catch {
    Write-Output "SEND FAIL: $($_.Exception.Message)"
    exit 1
}
