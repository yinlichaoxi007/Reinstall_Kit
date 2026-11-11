<#
.SYNOPSIS
    内存瘦身脚本 —— 针对 Windows 11 26H2 / 16GB 机器，回收 explorer 句柄泄漏与冗余常驻

.DESCRIPTION
    默认只做检查与报告，不改任何东西。确认无误后加 -Apply 才真正执行。

    各动作彼此独立，可单独指定：
      报告（默认）        列出当前提交量、Top 进程、explorer 句柄与泄漏速率
      -RestartExplorer    重启 explorer.exe，回收其占用的已提交内存（无损）
      -BlockShellExt      把百度网盘 / WPS 的图标覆盖与右键扩展加入 Blocked 黑名单
      -BlockTortoise      同上，但针对 TortoiseGit / TortoiseSVN（会失去文件状态角标）
      -TrimServices       Dell 预装与 SmartByte 的网络服务改为手动启动
      -TrimStartup        取消若干后台常驻程序的自启动
      -Undo               从本次生成的备份还原（注册表 .reg + 自启动清单）

.PARAMETER Apply
    真正执行。不加则全部为干跑。

.EXAMPLE
    .\12-内存瘦身.ps1
    只看报告。

.EXAMPLE
    .\12-内存瘦身.ps1 -RestartExplorer -Apply
    只重启 explorer，立即回收内存。

.EXAMPLE
    .\12-内存瘦身.ps1 -BlockShellExt -TrimServices -Apply
    屏蔽百度网盘/WPS 的 shell 扩展并停用 Dell 预装服务。

.NOTES
    需要管理员权限的动作：-BlockShellExt / -BlockTortoise / -TrimServices / -Undo
    -RestartExplorer 与 -TrimStartup 在普通权限下即可。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$RestartExplorer,
    [switch]$BlockShellExt,
    [switch]$BlockTortoise,
    [switch]$TrimServices,
    [switch]$TrimStartup,
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'
$script:KitRoot = Split-Path -Parent $PSScriptRoot
if (-not $script:KitRoot) { $script:KitRoot = $PSScriptRoot }
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:BackupDir = Join-Path $script:KitRoot ("backup\memslim-" + $script:Stamp)

# ---------------------------------------------------------------- 输出
function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}
function Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-- ' + $Text) -ForegroundColor Yellow
}
function GB { param([double]$Bytes) return [math]::Round($Bytes / 1GB, 2) }
function MB { param([double]$Bytes) return [math]::Round($Bytes / 1MB, 0) }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Admin

# ---------------------------------------------------------------- 1. 报告
function Invoke-Report {
    Head '内存现状'

    $os = Get-CimInstance Win32_OperatingSystem
    $totalPhys = [double]$os.TotalVisibleMemorySize * 1KB
    $freePhys = [double]$os.FreePhysicalMemory * 1KB

    $commitUsed = 0; $commitLimit = 0
    try {
        $perf = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
        $commitLimit = [double]$perf.CommitLimit
        $commitUsed = [double]$perf.CommittedBytes
    } catch { }

    if ($commitLimit -gt 0) {
        Say ('  物理内存        {0} GB（可用 {1} GB）' -f (GB $totalPhys), (GB $freePhys))
        Say ('  已提交          {0} GB / 上限 {1} GB  —— 占物理 {2}%' -f `
            (GB $commitUsed), (GB $commitLimit), [math]::Round($commitUsed / $totalPhys * 100))
    } else {
        Say ('  物理内存        {0} GB（可用 {1} GB）' -f (GB $totalPhys), (GB $freePhys))
        Say '  已提交          读取失败（需要更高权限），跳过'
    }

    $uptime = (Get-Date) - $os.LastBootUpTime
    Say ('  开机时长        {0} 天 {1} 小时' -f $uptime.Days, $uptime.Hours)
    if ($uptime.Days -ge 2) {
        Say '  ↑ 超过 2 天没关机，长时间运行的进程会持续膨胀' 'DarkYellow'
    }

    Step '占用已提交最多的 15 个进程'
    $procs = Get-Process | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 15
    $rows = @()
    foreach ($p in $procs) {
        $rows += [pscustomobject]@{
            进程   = $p.ProcessName
            PID    = $p.Id
            已提交 = (MB $p.PrivateMemorySize64)
            工作集 = (MB $p.WorkingSet64)
            句柄   = $p.HandleCount
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 100 | Write-Host

    Step '按程序名聚合（多进程程序合并）'
    $agg = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            程序   = $_.Name
            进程数 = $_.Count
            已提交 = [math]::Round((($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1MB)
            工作集 = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
        }
    } | Sort-Object 已提交 -Descending | Select-Object -First 12
    $agg | Format-Table -AutoSize | Out-String -Width 100 | Write-Host

    Step 'explorer.exe 句柄健康度'
    $exps = @(Get-Process explorer -ErrorAction SilentlyContinue)
    if ($exps.Count -eq 0) {
        Say '  未找到 explorer 进程' 'DarkYellow'
        return
    }

    Say '  正常 explorer 的句柄数在 3000 ~ 8000 之间；上万即为泄漏。' 'DarkGray'
    foreach ($e in $exps) {
        $lvl = 'Green'
        $verdict = '正常'
        if ($e.HandleCount -gt 50000) { $lvl = 'Red'; $verdict = '严重泄漏' }
        elseif ($e.HandleCount -gt 15000) { $lvl = 'Yellow'; $verdict = '疑似泄漏' }
        $age = (Get-Date) - $e.StartTime
        Write-Host ('     PID {0,-6} 句柄 {1,-8} 已提交 {2,6} MB  运行 {3} 天 {4} 小时  ->  {5}' -f `
            $e.Id, $e.HandleCount, (MB $e.PrivateMemorySize64), $age.Days, $age.Hours, $verdict) -ForegroundColor $lvl
    }

    if ($exps.Count -gt 1) {
        Say ('  ↑ 当前有 {0} 个 explorer 实例。正常应只有 1 个，多出来的通常是残留，可一并重启回收。' -f $exps.Count) 'DarkYellow'
    }

    # 泄漏速率：采样 30 秒
    Step '句柄泄漏速率（采样 30 秒，请勿操作资源管理器）'
    $before = @{}
    foreach ($e in $exps) { $before[$e.Id] = $e.HandleCount }
    Start-Sleep -Seconds 30
    $anyGrow = $false
    foreach ($id in $before.Keys) {
        $cur = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $cur) {
            Say ('     PID {0} 已退出' -f $id) 'DarkGray'
            continue
        }
        $d = $cur.HandleCount - $before[$id]
        $rate = [math]::Round($d / 30.0 * 60, 0)
        if ($d -ge 0) { $signed = '+' + $d } else { $signed = [string]$d }
        $signedRate = $rate
        if ($rate -ge 0) { $signedRate = '+' + $rate }
        Write-Host ('     PID {0,-6} 句柄 {1} -> {2}  （30 秒 {3}，折合每分钟 {4}）' -f `
            $id, $before[$id], $cur.HandleCount, $signed, $signedRate) -ForegroundColor $(if ($d -gt 20) { 'Red' } else { 'Green' })
        if ($d -gt 20) { $anyGrow = $true }
    }
    if ($anyGrow) {
        Say '  ↑ 句柄在持续增长 = 有 shell 扩展在泄漏。执行 -RestartExplorer 可立即回收，' 'Red'
        Say '    但要根治需定位到具体扩展，见 02-内存诊断与对策.md 的 A/B 排查法。' 'Red'
    } else {
        Say '  句柄基本稳定，当前占用属于"静态占用"而非泄漏。' 'Green'
    }

    Step '图标覆盖槽位占用（explorer 只加载前 15 条）'
    $overlayPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
    $names = @()
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($overlayPath)
        if ($key) {
            $names = $key.GetSubKeyNames()
            $key.Close()
        }
    } catch { }
    if ($names.Count -eq 0) {
        Say '  读取失败（需要管理员权限）' 'DarkYellow'
    } else {
        # 用序数排序复刻注册表枚举顺序：名称前导空格越多越靠前
        $sorted = [string[]]$names.Clone()
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        Say ('  注册了 {0} 条，实际只加载 15 条：' -f $sorted.Count)
        for ($i = 0; $i -lt [math]::Min(15, $sorted.Count); $i++) {
            Write-Host ('     {0,2}. {1}' -f ($i + 1), $sorted[$i].Trim()) -ForegroundColor Gray
        }
        if ($sorted.Count -gt 15) {
            Say ('     其余 {0} 条被静默丢弃（含百度网盘想要的另外 6 个角标）' -f ($sorted.Count - 15)) 'DarkGray'
        }
    }
}

# ---------------------------------------------------------------- 2. 重启 explorer
function Invoke-RestartExplorer {
    Head '重启 explorer.exe'

    $exps = @(Get-Process explorer -ErrorAction SilentlyContinue)
    if ($exps.Count -eq 0) {
        Say '  没有 explorer 在跑，直接启一个。' 'DarkYellow'
    }

    $before = 0
    foreach ($e in $exps) { $before += $e.PrivateMemorySize64 }
    $beforeH = 0
    foreach ($e in $exps) { $beforeH += $e.HandleCount }

    Say ('  重启前：{0} 个实例，已提交合计 {1} MB，句柄合计 {2}' -f $exps.Count, (MB $before), $beforeH)

    if (-not $Apply) {
        Say '  [干跑] 将结束以上进程并重新启动 explorer。桌面与任务栏会闪一下，已打开的窗口不受影响。' 'Yellow'
        return
    }

    Say '  正在结束 explorer ...'
    foreach ($e in $exps) {
        try { Stop-Process -Id $e.Id -Force -ErrorAction Stop } catch {
            Say ('     结束 PID {0} 失败：{1}' -f $e.Id, $_.Exception.Message) 'DarkYellow'
        }
    }
    Start-Sleep -Seconds 2

    Say '  正在启动 explorer ...'
    Start-Process 'explorer.exe'
    Start-Sleep -Seconds 4

    $after = @(Get-Process explorer -ErrorAction SilentlyContinue)
    $afterBytes = 0
    foreach ($e in $after) { $afterBytes += $e.PrivateMemorySize64 }
    $afterH = 0
    foreach ($e in $after) { $afterH += $e.HandleCount }

    Say ('  重启后：{0} 个实例，已提交合计 {1} MB，句柄合计 {2}' -f $after.Count, (MB $afterBytes), $afterH) 'Green'
    Say ('  回收约 {0} MB' -f (MB ($before - $afterBytes))) 'Green'
}

# ---------------------------------------------------------------- 3. 屏蔽 shell 扩展
# 说明：HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked
#      值是 CLSID 作为名称、空字符串作为数据。explorer 见到就不加载，且完全可逆。
$ExtBaidu = [ordered]@{
    '{C568C78A-652C-425B-8E6B-FFA73043302D}' = '百度网盘 角标 WorkspaceExt0'
    '{2A6FE247-5DA3-4732-9626-77820518FD77}' = '百度网盘 角标 WorkspaceExt1'
    '{FF895810-293B-464A-93F2-82D11E07EEC8}' = '百度网盘 角标 WorkspaceExt2'
    '{D8BE1E70-244A-46F0-BC5B-077D5F29EED8}' = '百度网盘 角标 WorkspaceExt3'
    '{7FAAC51E-19C2-4E2D-B598-A8D32E45BA48}' = '百度网盘 角标 WorkspaceExt4'
    '{2433C980-3DAB-43CA-99EB-01D5771054D0}' = '百度网盘 角标 WorkspaceExt5'
    '{AA931BEA-7353-4F4C-821F-6DC922AA3C77}' = '百度网盘 角标 WorkspaceExt6'
    '{6D85624F-305A-491d-8848-C1927AA0D790}' = '百度网盘 右键菜单 YunShellExt'
}
$ExtWps = [ordered]@{
    '{0E9063DD-9AAF-46EA-9F69-F3B005506097}' = 'WPS 角标 Abnormal'
    '{7610FA47-AAE9-414B-8253-BED61C646531}' = 'WPS 角标 Normal'
    '{B57A6468-3426-4F07-858E-70B5C255B129}' = 'WPS 角标 RootSyncFolder'
    '{3BA9D66D-AA36-4569-9BBB-DD4440DEA54F}' = 'WPS 角标 Update'
    '{AA147FFB-0B1F-4BB1-9B1E-8D062B35C146}' = 'WPS 右键菜单 QingNse'
}
$ExtTortoise = [ordered]@{
    '{C5994560-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 1Normal'
    '{C5994561-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 2Modified'
    '{C5994562-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 3Conflict'
    '{C5994563-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 4Locked'
    '{C5994564-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 5ReadOnly'
    '{C5994565-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 6Deleted'
    '{C5994566-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 7Added'
    '{C5994567-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 8Ignored'
    '{C5994568-53D9-4125-87C9-F193FC689CB2}' = 'Tortoise 角标 9Unversioned'
}

$BlockedKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'

function Backup-RegKey {
    param([string]$PsPath, [string]$FileName)
    if (-not $Apply) { return }
    if (-not (Test-Path $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
    $regPath = $PsPath -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
    $out = Join-Path $script:BackupDir $FileName
    $null = & reg.exe export $regPath $out /y 2>&1
    if (Test-Path $out) {
        Say ('  已备份注册表 -> {0}' -f $out) 'DarkGray'
    } else {
        Say ('  注册表备份失败：{0}' -f $regPath) 'DarkYellow'
    }
}

function Invoke-BlockExt {
    param([System.Collections.Specialized.OrderedDictionary]$Map, [string]$Title, [string]$Tag)

    Head ('屏蔽 shell 扩展 —— ' + $Title)

    if (-not $isAdmin) {
        Say '  需要管理员权限。请用「以管理员身份运行 PowerShell」重开后再执行。' 'Red'
        return
    }

    Backup-RegKey -PsPath $BlockedKey -FileName ('Blocked-' + $Tag + '.reg')

    if (-not (Test-Path $BlockedKey)) {
        if ($Apply) { New-Item -Path $BlockedKey -Force | Out-Null }
    }

    $existing = @()
    if (Test-Path $BlockedKey) {
        $existing = (Get-Item $BlockedKey).Property
    }

    $new = 0
    foreach ($clsid in $Map.Keys) {
        $desc = $Map[$clsid]
        if ($existing -contains $clsid) {
            Say ('  [已有] {0}' -f $desc) 'DarkGray'
            continue
        }
        Say ('  [加入] {0}   {1}' -f $desc, $clsid) 'Yellow'
        if ($Apply) {
            New-ItemProperty -Path $BlockedKey -Name $clsid -Value '' -PropertyType String -Force | Out-Null
        }
        $new++
    }

    if (-not $Apply) {
        Say ('  [干跑] 将新增 {0} 条黑名单记录。加 -Apply 执行。' -f $new) 'Yellow'
        return
    }
    Say ('  完成，新增 {0} 条。重启 explorer 后生效。' -f $new) 'Green'
    Say '  撤销方式：-Undo，或手动导入本目录下的 .reg 备份' 'DarkGray'
}

# ---------------------------------------------------------------- 4. 服务
$SvcTargets = @(
    @{ Name = 'SupportAssistAgent';            Label = 'Dell SupportAssist' },
    @{ Name = 'Dell SupportAssist Remediation'; Label = 'Dell SupportAssist 修复组件' },
    @{ Name = 'DellClientManagementService';   Label = 'Dell 客户端管理' },
    @{ Name = 'Dell Digital Delivery Services'; Label = 'Dell 数字交付' },
    @{ Name = 'DellConnectedServiceDelivery';  Label = 'Dell 联网服务交付' },
    @{ Name = 'DellTechHub';                   Label = 'Dell TechHub' },
    @{ Name = 'SmartByte Network Service x64'; Label = 'SmartByte 网络服务（Rivet 预装，已知问题多）' },
    @{ Name = 'SmartByte Analytics Service';   Label = 'SmartByte 遥测' }
)

function Invoke-TrimServices {
    Head '停用冗余服务（改为手动启动）'

    if (-not $isAdmin) {
        Say '  需要管理员权限。' 'Red'
        return
    }

    $changed = 0
    foreach ($t in $SvcTargets) {
        $svc = Get-Service -Name $t.Name -ErrorAction SilentlyContinue
        if (-not $svc) {
            Say ('  [无此服务] {0}' -f $t.Label) 'DarkGray'
            continue
        }
        if ($svc.StartType -eq 'Manual' -or $svc.StartType -eq 'Disabled') {
            Say ('  [已手动] {0}' -f $t.Label) 'DarkGray'
            continue
        }
        Say ('  [改为手动] {0}  （当前 {1} / {2}）' -f $t.Label, $svc.Status, $svc.StartType) 'Yellow'
        if ($Apply) {
            try {
                Set-Service -Name $t.Name -StartupType Manual -ErrorAction Stop
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $t.Name -Force -ErrorAction SilentlyContinue
                }
                $changed++
            } catch {
                Say ('     失败：{0}' -f $_.Exception.Message) 'DarkYellow'
            }
        } else {
            $changed++
        }
    }

    if (-not $Apply) {
        Say ('  [干跑] 将改动 {0} 个服务。加 -Apply 执行。' -f $changed) 'Yellow'
        return
    }

    Say ''
    Say '  这些服务改为"手动"后不会消失，需要时仍会被系统或程序拉起。' 'DarkGray'
    Say '  如需彻底禁用，自行执行：sc.exe config "<服务名>" start= disabled' 'DarkGray'
}

# ---------------------------------------------------------------- 5. 自启动
$StartupTargets = @(
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'Docker Desktop';    Label = 'Docker Desktop（不常用就别开机自启）' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'BaiduYunDetect';    Label = '百度网盘 检测服务' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'Anytxt Searcher 1.3.1380 Free'; Label = 'AnyTXT 旧版本（与 1.3.1225 重复）' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'Lertaro';           Label = 'Lertaro' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'LocalSend';         Label = 'LocalSend' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'SnowShot';          Label = 'SnowShot 截图' }
)

function Invoke-TrimStartup {
    Head '取消冗余自启动'

    $changed = 0
    $removed = @()
    foreach ($t in $StartupTargets) {
        $val = $null
        try {
            $val = (Get-ItemProperty -Path $t.Key -Name $t.Name -ErrorAction Stop).($t.Name)
        } catch {
            Say ('  [不存在] {0}' -f $t.Label) 'DarkGray'
            continue
        }
        Say ('  [移除] {0}' -f $t.Label) 'Yellow'
        Say ('          {0}' -f $val) 'DarkGray'
        if ($Apply) {
            try {
                Remove-ItemProperty -Path $t.Key -Name $t.Name -Force -ErrorAction Stop
                $removed += [pscustomobject]@{ Key = $t.Key; Name = $t.Name; Value = $val }
                $changed++
            } catch {
                Say ('          失败：{0}' -f $_.Exception.Message) 'DarkYellow'
            }
        } else {
            $changed++
        }
    }

    if (-not $Apply) {
        Say ('  [干跑] 将移除 {0} 项。加 -Apply 执行。' -f $changed) 'Yellow'
        return
    }

    if ($removed.Count -gt 0) {
        if (-not (Test-Path $script:BackupDir)) {
            New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
        }
        $json = Join-Path $script:BackupDir 'startup-removed.json'
        $removed | ConvertTo-Json -Depth 4 | Out-File -FilePath $json -Encoding UTF8
        Say ('  已记录还原清单 -> {0}' -f $json) 'DarkGray'
    }
    Say ('  完成，移除 {0} 项。' -f $changed) 'Green'
}

# ---------------------------------------------------------------- 6. 撤销
function Invoke-Undo {
    Head '从备份还原'

    if (-not $isAdmin) {
        Say '  需要管理员权限（还原 HKLM 注册表）。' 'Red'
        return
    }

    if (-not (Test-Path $script:BackupDir)) {
        Say ('  本次没有备份目录：{0}' -f $script:BackupDir) 'DarkYellow'
        Say '  备份位于 <工程包>\backup\memslim-*，请手动指定要还原的时间戳目录。' 'DarkYellow'
        $parent = Join-Path $script:KitRoot 'backup'
        if (Test-Path $parent) {
            Say '  现有备份：'
            Get-ChildItem $parent -Directory | ForEach-Object { Say ('     ' + $_.Name) }
        }
        return
    }

    $regFiles = @(Get-ChildItem $script:BackupDir -Filter '*.reg' -ErrorAction SilentlyContinue)
    foreach ($f in $regFiles) {
        Say ('  导入 {0} ...' -f $f.Name) 'Yellow'
        if ($Apply) {
            $null = & reg.exe import $f.FullName 2>&1
            Say ('    完成') 'Green'
        }
    }

    $json = Join-Path $script:BackupDir 'startup-removed.json'
    if (Test-Path $json) {
        $items = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($it in $items) {
            Say ('  恢复自启动 {0}' -f $it.Name) 'Yellow'
            if ($Apply) {
                New-ItemProperty -Path $it.Key -Name $it.Name -Value $it.Value -PropertyType String -Force | Out-Null
            }
        }
    }

    if (-not $Apply) {
        Say '  [干跑] 加 -Apply 真正导入。' 'Yellow'
    } else {
        Say '  还原完成，重启 explorer 后生效。' 'Green'
    }
}

# ---------------------------------------------------------------- 主流程
Head '内存瘦身脚本'
Say ('  模式：{0}' -f $(if ($Apply) { '执行（-Apply）' } else { '只检查，不改动（干跑）' })) $(if ($Apply) { 'Red' } else { 'Green' })
Say ('  权限：{0}' -f $(if ($isAdmin) { '管理员' } else { '普通用户' })) $(if ($isAdmin) { 'Green' } else { 'Yellow' })
if ($Apply) { Say ('  备份目录：{0}' -f $script:BackupDir) 'DarkGray' }

$didSomething = $false

if ($RestartExplorer) { Invoke-RestartExplorer; $didSomething = $true }
if ($BlockShellExt) {
    Invoke-BlockExt -Map $ExtBaidu -Title '百度网盘' -Tag 'baidu'
    Invoke-BlockExt -Map $ExtWps -Title 'WPS' -Tag 'wps'
    $didSomething = $true
}
if ($BlockTortoise) {
    Say ''
    Say '  注意：Tortoise 角标占了 15 个槽位里的 9 个，屏蔽后文件/文件夹不再显示 git 状态角标。' 'Yellow'
    Say '        TortoiseGit 的右键菜单不受影响（那是另一套 CLSID，未列入）。' 'Yellow'
    Invoke-BlockExt -Map $ExtTortoise -Title 'TortoiseGit / TortoiseSVN 角标' -Tag 'tortoise'
    $didSomething = $true
}
if ($TrimServices) { Invoke-TrimServices; $didSomething = $true }
if ($TrimStartup) { Invoke-TrimStartup; $didSomething = $true }
if ($Undo) { Invoke-Undo; $didSomething = $true }

if (-not $didSomething) {
    Invoke-Report
    Head '可执行的动作'
    Say '  -RestartExplorer   重启 explorer，回收其占用的已提交内存（推荐先做这个）' 'White'
    Say '  -BlockShellExt     屏蔽百度网盘与 WPS 的角标/右键扩展（需管理员）' 'White'
    Say '  -BlockTortoise     屏蔽 Tortoise 的 9 个角标（会失去 git 状态角标）' 'White'
    Say '  -TrimServices      Dell 预装与 SmartByte 服务改为手动（需管理员）' 'White'
    Say '  -TrimStartup       取消 6 项冗余自启动' 'White'
    Say '  -Undo              还原本次备份' 'White'
    Say ''
    Say '  以上都要配 -Apply 才真正执行。' 'DarkGray'
    Say '  例：.\12-内存瘦身.ps1 -RestartExplorer -Apply' 'White'
}

Say ''
