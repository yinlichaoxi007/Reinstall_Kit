# Explorer 句柄泄漏守护脚本
# 针对：explorer.exe 的 XAML 命令栏泄漏 CommandStore 注册表句柄（微软缺陷，见 05-*.md）
# 兼容 Windows PowerShell 5.1，无需管理员权限

param(
    [ValidateSet('Status', 'Restart', 'Watch', 'Install', 'Uninstall', 'SeparateProcess')]
    [string]$Action = 'Status',

    # 句柄数超过此值就处置（正常 explorer 为 2000~6000）
    [int]$Threshold = 30000,

    # 两次自动重启之间的最小间隔（分钟）
    [int]$CooldownMinutes = 240,

    # Watch 模式的巡检间隔（分钟）
    [int]$IntervalMinutes = 30,

    # SeparateProcess 动作的开关值
    [ValidateSet('On', 'Off')]
    [string]$Separate = 'On',

    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:LogDir = Join-Path $script:Root 'logs'
$script:LogFile = Join-Path $script:LogDir 'explorer-guard.log'
$script:StateFile = Join-Path $script:LogDir 'explorer-guard.state'

if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Write-Log {
    param([string]$Text)
    $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

# ---------- 判断是否有文件操作在进行（有则不要重启 shell） ----------
try {
    Add-Type -Namespace WbGuard -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
'@ -ErrorAction Stop
} catch {
    # 类型已存在，忽略
}

function Test-BusyFileOperation {
    $hwnd = [WbGuard.Native]::FindWindowW('OperationStatusWindow', $null)
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    return [WbGuard.Native]::IsWindowVisible($hwnd)
}

function Get-ExplorerList {
    return @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
}

function Get-ExplorerSnapshot {
    $list = Get-ExplorerList
    $items = @()
    foreach ($p in $list) {
        $ws = 0
        try { $ws = [int][math]::Round($p.WorkingSet64 / 1MB, 0) } catch { }
        $cpu = 0
        try { $cpu = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1) } catch { }
        $start = ''
        try { $start = $p.StartTime.ToString('MM-dd HH:mm') } catch { }
        $items += [pscustomobject]@{
            PID      = $p.Id
            Handles  = $p.HandleCount
            MemMB    = $ws
            CpuSec   = $cpu
            Started  = $start
        }
    }
    return $items
}

function Get-ThresholdState {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    try {
        return [datetime]::Parse((Get-Content -LiteralPath $script:StateFile -Raw).Trim())
    } catch {
        return $null
    }
}

function Set-ThresholdState {
    Set-Content -LiteralPath $script:StateFile -Value (Get-Date -Format 'o') -Encoding UTF8
}

# ---------- 安全重启 ----------
function Invoke-ExplorerRestart {
    param([string]$Reason)

    if ($DryRun) {
        Say ('  [演练] 本应重启 explorer，原因：' + $Reason) 'Yellow'
        return $false
    }
    if (Test-BusyFileOperation) {
        Say '  检测到文件操作窗口（复制/移动进行中），本次放弃重启' 'Yellow'
        Write-Log ('跳过重启：有文件操作在进行（' + $Reason + '）')
        return $false
    }

    $before = Get-ExplorerSnapshot
    $maxBefore = 0
    foreach ($x in $before) { if ($x.Handles -gt $maxBefore) { $maxBefore = $x.Handles } }

    Say ('  正在重启 explorer（当前最大句柄 {0:N0}）...' -f $maxBefore) 'Yellow'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath 'explorer.exe'
        Start-Sleep -Seconds 6
    }

    $after = Get-ExplorerSnapshot
    $maxAfter = 0
    foreach ($x in $after) { if ($x.Handles -gt $maxAfter) { $maxAfter = $x.Handles } }
    Say ('  完成：最大句柄 {0:N0} -> {1:N0}' -f $maxBefore, $maxAfter) 'Green'
    Write-Log ('已重启 explorer（{0}）：句柄 {1} -> {2}' -f $Reason, $maxBefore, $maxAfter)
    Set-ThresholdState
    return $true
}

# ---------- Status ----------
function Show-Status {
    Say ''
    Say '=== explorer 句柄现状 ===' 'Cyan'
    $snap = Get-ExplorerSnapshot
    if ($snap.Count -eq 0) {
        Say '  没有找到 explorer 进程' 'Red'
        return
    }
    Say ('  {0,-8}{1,12}{2,10}{3,10}  {4}' -f 'PID', '句柄', '内存MB', 'CPU秒', '启动')
    Say ('  {0,-8}{1,12}{2,10}{3,10}  {4}' -f '--------', '------------', '----------', '----------', '----------')
    foreach ($x in $snap) {
        Say ('  {0,-8}{1,12:N0}{2,10}{3,10}  {4}' -f $x.PID, $x.Handles, $x.MemMB, $x.CpuSec, $x.Started)
    }
    Say ''
    $max = 0
    $sum = 0
    foreach ($x in $snap) {
        $sum += $x.Handles
        if ($x.Handles -gt $max) { $max = $x.Handles }
    }

    Say ('合计句柄 {0:N0}，单进程最大 {1:N0}，阈值 {2:N0}' -f $sum, $max, $Threshold)
    if ($max -ge $Threshold) {
        Say '  [异常] 已超过阈值，需要处置：加 -Restart 参数' 'Red'
    } elseif ($max -ge 10000) {
        Say '  [注意] 已有累积，建议近期重启一次 explorer' 'Yellow'
    } else {
        Say '  [正常] 处于健康区间（2000~6000）' 'Green'
    }

    Say ''
    Say '=== 15 秒速率采样 ===' 'Cyan'
    $a = @{}
    foreach ($p in Get-ExplorerList) { $a[$p.Id] = $p.HandleCount }
    Start-Sleep -Seconds 15
    $total = 0
    foreach ($p in Get-ExplorerList) {
        $old = 0
        if ($a.ContainsKey($p.Id)) { $old = $a[$p.Id] }
        $d = $p.HandleCount - $old
        $total += $d
        Say ('  PID {0,-6} 句柄 {1,-7} 增量 {2,6}' -f $p.Id, $p.HandleCount, $d)
    }
    Say ('  合计每分钟 {0:N0}' -f ($total * 4))
    if (($total * 4) -gt 500) {
        Say '  [异常] 泄漏正在进行。最小化资源管理器窗口可立刻让速率归零（验证用）' 'Red'
    } else {
        Say '  [正常]' 'Green'
    }

    $st = Get-ThresholdState
    if ($st) {
        Say ''
        Say ('上次处置时间：{0}' -f $st.ToString('yyyy-MM-dd HH:mm'))
    }
    Say ''
}

# ---------- Watch ----------
function Invoke-Watch {
    Write-Log ('守护启动：阈值 {0}，巡检 {1} 分钟，冷却 {2} 分钟' -f $Threshold, $IntervalMinutes, $CooldownMinutes)
    while ($true) {
        $snap = Get-ExplorerSnapshot
        $max = 0
        foreach ($x in $snap) { if ($x.Handles -gt $max) { $max = $x.Handles } }

        if ($max -ge $Threshold) {
            $st = Get-ThresholdState
            $canAct = $true
            if ($st) {
                $mins = ((Get-Date) - $st).TotalMinutes
                if ($mins -lt $CooldownMinutes) {
                    $canAct = $false
                    Write-Log ('超阈值（{0}）但仍在冷却期（已过 {1:N0} 分钟）' -f $max, $mins)
                }
            }
            if ($canAct) {
                Invoke-ExplorerRestart ('句柄 {0} 超过阈值 {1}' -f $max, $Threshold) | Out-Null
            }
        }
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
}

# ---------- Install / Uninstall ----------
function Install-Guard {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'ExplorerGuard.lnk'
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }

    if ($DryRun) {
        Say ('  [演练] 将在启动文件夹创建快捷方式：' + $lnkPath) 'Yellow'
        Say ('  [演练] 目标：powershell -File "' + $self + '" -Action Watch') 'Yellow'
        return
    }

    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Watch -Threshold {1} -IntervalMinutes {2}' -f $self, $Threshold, $IntervalMinutes)
    $lnk.WorkingDirectory = $script:Root
    $lnk.WindowStyle = 7
    $lnk.Description = 'Explorer 句柄泄漏守护'
    $lnk.Save()

    Say ('  已创建登录自启：' + $lnkPath) 'Green'
    Write-Log ('安装守护：' + $lnkPath)
    Say '  下次登录生效。想立刻生效，直接后台跑：' 'Gray'
    Say ('    powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Watch' -f $self) 'Gray'
}

function Uninstall-Guard {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'ExplorerGuard.lnk'
    if (Test-Path -LiteralPath $lnkPath) {
        if ($DryRun) {
            Say ('  [演练] 将删除：' + $lnkPath) 'Yellow'
        } else {
            Remove-Item -LiteralPath $lnkPath -Force
            Say ('  已删除：' + $lnkPath) 'Green'
            Write-Log '卸载守护'
        }
    } else {
        Say '  未安装（启动文件夹里没有 ExplorerGuard.lnk）' 'Yellow'
    }
    # 结束正在运行的守护实例
    $others = @()
    try {
        $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -ne $null -and $_.CommandLine -like '*5-explorer*' })
    } catch { }
    foreach ($o in $others) {
        if ($DryRun) {
            Say ('  [演练] 将结束守护进程 PID ' + $o.ProcessId) 'Yellow'
        } else {
            Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue
            Say ('  已结束守护进程 PID ' + $o.ProcessId) 'Green'
        }
    }
}

# ---------- SeparateProcess ----------
function Set-SeparateProcess {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $cur = $null
    try { $cur = (Get-ItemProperty -Path $path -Name 'SeparateProcess' -ErrorAction Stop).SeparateProcess } catch { }
    $target = 1
    if ($Separate -eq 'Off') { $target = 0 }

    Say ''
    Say ('当前 SeparateProcess = {0}' -f $(if ($null -eq $cur) { '未设置（默认 = 同进程）' } else { $cur }))
    if ($DryRun) {
        Say ('[演练] 将设置为 {0}（{1}）' -f $target, $Separate) 'Yellow'
        return
    }
    Set-ItemProperty -Path $path -Name 'SeparateProcess' -Value $target -Type DWord
    Say ('已设置为 {0}' -f $target) 'Green'
    Write-Log ('SeparateProcess -> ' + $target)
    Say '新开的文件夹窗口会各自使用独立 explorer.exe；关闭窗口即回收该窗口的全部泄漏。' 'Cyan'
    Say '代价：每个窗口多占约 40~60 MB。' 'Gray'
    Say ''
}

# ---------- 主流程 ----------
switch ($Action) {
    'Status' { Show-Status }
    'Restart' {
        Say ''
        Say '=== 重启 explorer ===' 'Cyan'
        Invoke-ExplorerRestart '手动执行' | Out-Null
    }
    'Watch' { Invoke-Watch }
    'Install' { Install-Guard }
    'Uninstall' { Uninstall-Guard }
    'SeparateProcess' { Set-SeparateProcess }
}
