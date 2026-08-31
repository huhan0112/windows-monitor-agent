# Windows 服务器监控系统 - 部署包

## 📦 包含内容

```
windows-monitor-deployment/
├── bin/                          # 二进制文件
│   ├── windows_exporter.exe      # Windows 指标采集器 (v0.31.8)
│   ├── prometheus.exe             # Prometheus 监控服务 (v3.14.0)
│   └── promtool.exe               # Prometheus 工具
├── config/                        # 配置文件
│   ├── windows_exporter.yaml      # 采集器配置
│   └── smtp.conf                  # 邮件通知配置（需要修改）
├── prometheus/                    # Prometheus 配置
│   ├── prometheus.yml             # 主配置文件
│   └── rules/
│       └── alert_rules.yml        # 告警规则
├── scripts/                       # 脚本
│   ├── Crash-Watchdog.ps1         # 崩溃监控脚本
│   └── Send-QQMail.ps1            # QQ 邮件发送脚本
├── state/                         # 状态文件目录（自动创建）
├── install.ps1                    # 一键安装脚本 ⭐
└── README.md                      # 本文件
```

## 🚀 快速部署（3 步完成）

### 步骤 1：上传到服务器
将整个 `windows-monitor-deployment` 文件夹上传到服务器任意位置

### 步骤 2：配置邮箱（重要）
编辑 `config\smtp.conf`，填写你的 QQ 邮箱信息：

```ini
SMTP_HOST=smtp.qq.com
SMTP_PORT=587
SMTP_USERNAME=你的QQ号@qq.com
SMTP_AUTH_CODE=你的授权码
FROM_ADDRESS=你的QQ号@qq.com
TO_ADDRESS=接收告警的邮箱
```

**获取 QQ 邮箱授权码：**
1. 登录 QQ 邮箱网页版
2. 设置 → 账户 → POP3/IMAP/SMTP/Exchange/CardDAV/CalDAV服务
3. 开启 IMAP/SMTP 服务
4. 生成授权码（16 位字符）

### 步骤 3：运行安装脚本
以**管理员身份**打开 PowerShell，执行：

```powershell
cd 你的上传路径\windows-monitor-deployment
.\install.ps1
```

或者指定安装位置和收件邮箱：

```powershell
.\install.ps1 -InstallPath "D:\monitoring" -ToEmail "admin@example.com"
```

## ✅ 安装脚本会自动完成

1. ✓ 检查端口占用（9182, 9090）
2. ✓ 创建目录结构（默认 C:\monitoring）
3. ✓ 复制所有文件
4. ✓ 配置 SMTP（如提供邮箱）
5. ✓ 安装 windows_exporter 服务并启动
6. ✓ 安装 Prometheus 开机自启任务并启动
7. ✓ 创建崩溃监控计划任务（每 5 分钟运行）
8. ✓ 验证所有服务和端点

## 📊 监控功能

### 实时指标监控
- **CPU 使用率**：持续 3 分钟 > 85% → 高负载告警，> 95% → 严重告警
- **内存使用率**：> 90% → 高负载告警，> 95% → 严重告警
- **磁盘空间**：剩余 < 10% → 告警

### 崩溃取证
监控 Windows 事件日志，自动捕获：
- Kernel-Power 41（意外关机）
- BugCheck 1001（蓝屏）
- WHEA 错误（硬件错误）

每次崩溃时自动收集：
- 事件详情和时间戳
- 系统日志快照
- 内存转储文件（如果存在）

### 告警去重
相同告警在持续触发期间只发送一次邮件，恢复后再次触发会重新通知，避免邮件轰炸

## 🌐 访问 Web UI

安装完成后，浏览器访问：

- **Prometheus**：http://服务器IP:9090
  - 查看所有指标
  - 执行 PromQL 查询
  - 查看告警规则状态

- **Metrics 端点**：http://服务器IP:9182/metrics
  - 查看原始指标数据

## 🔧 常用管理命令

### 查看运行状态
```powershell
# windows_exporter 服务
Get-Service windows_exporter | Select-Object Name, Status

# Prometheus 计划任务
Get-ScheduledTask -TaskName "WindowsMonitor-Prometheus" | Select-Object TaskName, State

# 看门狗计划任务
Get-ScheduledTask -TaskName "WindowsMonitor-CrashWatchdog" | Select-Object TaskName, State
```

### 重启服务
```powershell
# 重启 windows_exporter
Restart-Service windows_exporter

# 重启 Prometheus（计划任务，用 Stop + Start 两步）
Stop-ScheduledTask -TaskName "WindowsMonitor-Prometheus"
Start-ScheduledTask -TaskName "WindowsMonitor-Prometheus"
```

### 查看日志
```powershell
# windows_exporter 日志
Get-Content C:\monitoring\logs\exporter.log -Tail 50

# 崩溃监控日志
Get-Content C:\monitoring\logs\watchdog.log -Tail 50

# 告警状态
Get-Content C:\monitoring\state\last-alerts.json | ConvertFrom-Json
```

### 手动运行崩溃检测
```powershell
cd C:\monitoring\scripts
.\Crash-Watchdog.ps1
```

### 测试邮件发送
```powershell
cd C:\monitoring\scripts
.\Send-QQMail.ps1 -Subject "测试邮件" -Body "这是一封测试邮件" -ToAddress "你的邮箱"
```

## 🎯 GPU 监控说明

**注意**：windows_exporter v0.31.8 已移除 gpu 采集器，当前无法直接采集 GPU 温度/显存。

如需 GPU 监控，需改用 nvidia-smi 的 textfile 方式：
1. 用脚本定期执行 `nvidia-smi --query-gpu=...` 输出指标到文件
2. 配置 windows_exporter 的 `--collector.textfile.directories` 指向该目录
3. 再启用 alert_rules.yml 中的 GPU 规则

## 📝 修改告警阈值

编辑 `C:\monitoring\prometheus\rules\alert_rules.yml`，修改后重启 Prometheus：

```yaml
- alert: CPUHigh
  expr: 100 - (avg by(instance) (rate(windows_cpu_time_total{mode="idle"}[5m])) * 100) > 80
  #                                                                                    ↑ 修改这里
  for: 5m
```

重启生效：
```powershell
Stop-ScheduledTask -TaskName "WindowsMonitor-Prometheus"
Start-ScheduledTask -TaskName "WindowsMonitor-Prometheus"
```

## 🔒 安全配置

### 1. SMTP 配置文件保护
`smtp.conf` 已自动设置 ACL，仅 SYSTEM 和 Administrators 可读写

### 2. 防火墙规则（可选）
如需远程访问 Prometheus Web UI：

```powershell
New-NetFirewallRule -DisplayName "Prometheus" -Direction Inbound -LocalPort 9090 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Windows Exporter" -Direction Inbound -LocalPort 9182 -Protocol TCP -Action Allow
```

### 3. 建议
- 生产环境使用 HTTPS + 认证
- 限制 Web UI 访问 IP
- 定期更新二进制文件

## ❓ 故障排查

### 服务无法启动
```powershell
# 查看 Windows 事件日志
Get-EventLog -LogName Application -Source prometheus -Newest 10
Get-EventLog -LogName Application -Source windows_exporter -Newest 10
```

### 告警未发送
1. 检查 `C:\monitoring\logs\watchdog.log`
2. 验证 SMTP 配置：
   ```powershell
   $env:SMTP_CONFIG_FILE = "C:\monitoring\config\smtp.conf"
   C:\monitoring\scripts\Send-QQMail.ps1 -Subject "测试" -Body "测试" -ToAddress "你的邮箱"
   ```
3. 检查 QQ 邮箱授权码是否正确

### Prometheus 无数据
1. 访问 http://localhost:9182/metrics 确认 exporter 正常
2. 检查 Prometheus 配置：
   ```powershell
   C:\monitoring\bin\promtool.exe check config C:\monitoring\prometheus\prometheus.yml
   ```

## 📞 技术支持

- **日志位置**：`C:\monitoring\logs\`
- **配置位置**：`C:\monitoring\config\`
- **数据位置**：`C:\monitoring\prometheus\data\`

## 🔄 卸载

```powershell
# 停止并删除 windows_exporter 服务
Stop-Service windows_exporter
sc.exe delete windows_exporter

# 删除计划任务（Prometheus + 看门狗）
Unregister-ScheduledTask -TaskName "WindowsMonitor-Prometheus" -Confirm:$false
Unregister-ScheduledTask -TaskName "WindowsMonitor-CrashWatchdog" -Confirm:$false

# 停止 Prometheus 进程
Get-Process prometheus -ErrorAction SilentlyContinue | Stop-Process -Force

# 删除安装目录
Remove-Item C:\monitoring -Recurse -Force
```

---

**版本信息**
- windows_exporter: v0.31.8
- Prometheus: v3.14.0
- 更新日期: 2026-08-27
