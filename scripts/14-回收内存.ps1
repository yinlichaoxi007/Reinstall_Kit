# 14-回收内存.ps1
# 目标：把「已提交」里属于浪费的那部分收回来。默认只报告，不动手。
#
#   powershell -ExecutionPolicy Bypass -File "D:\Reinstall_Kit\scripts\14-回收内存.ps1"
#       只看现状与候选清单
#
#   powershell -ExecutionPolicy Bypass -File "D:\Reinstall_Kit\scripts\14-回收内存.ps1" -Apply -TrimMsBuild
#       结束空闲的 MSBuild 节点（VS 编译缓存，安全）
#
#   powershell -ExecutionPolicy Bypass -File "D:\Reinstall_Kit\scripts\14-回收内存.ps1" -Apply -QuitJoplin
#       结束 Joplin（会丢失未保存的正在编辑内容；托盘里的窗口先手动看一眼）
#
#   powershell -ExecutionPolicy Bypass -File "D:\Reinstall_Kit\scripts\14-回收内存.ps1" -Apply -QuitBackground
#       结束明确闲置的后台常驻程序
#
#   powershell -ExecutionPolicy Bypass -File "D:\Reinstall_Kit\scripts\14-回收内存.ps1" -Apply -TrimMsBuild -QuitJoplin -QuitBackground
#       一次全做
#
# 设计原则：
#   * 不加 -Apply 一律不动手
#   * 绝不结束 devenv / WorkBuddy / 代码编辑器 / 微信 —— 这些有你未保存的东西
#   * MSBuild 节点先测 5 秒 CPU，有活动就整组跳过，不会打断正在跑的编译

param(
    [switch]$Apply,
    [switch]$TrimMsBuild,
    [switch]$QuitJoplin,
    [switch]$QuitBackground
)

$ErrorActionPreference = 'Continue'

function Say([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
}
function Head([string]$msg) {
    Write-Host ''
    Write-Host $msg -ForegroundColor Cyan
    Write-Host ('-' * 62) -ForegroundColor DarkCyan
}
function MB([double]$bytes) {
    return [math]::Round($bytes / 1MB, 0)
}

# ---------------- 0. 前置检查 ----------------
$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if (-not $os) {
    Say '无法读取系统信息，退出。' 'Red'
    exit 1
}
$totalPhysGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$availPhysGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$commitLimitGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 2)
$commitFreeGB = [math]::Round($os.FreeVirtualMemory / 1MB, 2)
$commitUsedGB = [math]::Round($commitLimitGB - $commitFreeGB, 2)
$commitPct = if ($commitLimitGB -gt 0) { [math]::Round($commitUsedGB / $commitLimitGB * 100, 0) } else { 0 }

Head '一、当前内存状态'
Write-Host ('  物理内存      {0,6:N2} GB      可用 {1,6:N2} GB' -f $totalPhysGB, $availPhysGB)
Write-Host ('  已提交        {0,6:N2} GB      {1}% of {2:N2} GB' -f $commitUsedGB, $commitPct, $commitLimitGB)
$color = 'Green'
if ($commitPct -ge 90) { $color = 'Red' } elseif ($commitPct -ge 75) { $color = 'Yellow' }
Write-Host ('  提交压力      {0}%' -f $commitPct) -ForegroundColor $color

# 页面文件
try {
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    foreach ($p in $pf) {
        Write-Host ('  页面文件      {0}  已分配 {1,5:N0} MB  峰值 {2,5:N0} MB' -f $p.Name, $p.AllocatedBaseSize, $p.PeakUsage)
    }
} catch {}

# 磁盘
foreach ($d in @('C:\', 'D:\')) {
    try {
        $di = Get-PSDrive -Name $d.Substring(0, 1) -ErrorAction Stop
        $freeGB = [math]::Round($di.Free / 1GB, 1)
        $c = 'Gray'
        if ($freeGB -lt 20) { $c = 'Yellow' }
        if ($freeGB -lt 10) { $c = 'Red' }
        Write-Host ('  磁盘 {0}       剩余 {1,6:N1} GB' -f $d.Substring(0, 2), $freeGB) -ForegroundColor $c
    } catch {}
}
Write-Host ('  权限          ' + $(if ($isAdmin) { '管理员' } else { '普通用户（部分操作不可用）' }))

# ---------------- 1. 现状：谁占着提交 ----------------
Head '二、私有提交 TOP 15（按程序聚合）'
$all = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -gt 4 }
$groups = @{}
foreach ($p in $all) {
    $k = $p.ProcessName.ToLower()
    if (-not $groups.ContainsKey($k)) {
        $groups[$k] = [pscustomobject]@{ Name = $p.ProcessName; Count = 0; Priv = 0; Ws = 0; Cpu = 0 }
    }
    $g = $groups[$k]
    $g.Count++
    try { $g.Priv += $p.PrivateMemorySize64 } catch {}
    try { $g.Ws += $p.WorkingSet64 } catch {}
    try { $g.Cpu += $p.TotalProcessorTime.TotalSeconds } catch {}
}
$rank = $groups.Values | Sort-Object -Property Priv -Descending | Select-Object -First 15
Write-Host ('  {0,-24} {1,4} {2,10} {3,10}' -f '程序', '实例', '私有提交', '工作集') -ForegroundColor DarkGray
foreach ($g in $rank) {
    $c = 'Gray'
    if ($g.Priv -gt 1GB) { $c = 'Yellow' }
    Write-Host ('  {0,-24} {1,4} {2,8:N0} MB {3,8:N0} MB' -f $g.Name, $g.Count, (MB $g.Priv), (MB $g.Ws)) -ForegroundColor $c
}
$sumPriv = ($groups.Values | Measure-Object -Property Priv -Sum).Sum
Write-Host ('  {0,-24} {1,4} {2,8:N0} MB' -f '（全部进程合计）', $all.Count, (MB $sumPriv)) -ForegroundColor DarkGray
Write-Host ''
Write-Host ('  已提交 {0:N1} GB − 进程私有 {1:N1} GB = 缺口 {2:N1} GB（内核池 + 共享提交）' -f `
        $commitUsedGB, ($sumPriv / 1GB), ($commitUsedGB - $sumPriv / 1GB)) -ForegroundColor DarkGray

# ---------------- 2. 候选清单 ----------------
Head '三、可回收候选'
$cands = @()
$reclaimTotal = 0

# 2.1 MSBuild 节点
$mb = @(Get-Process -Name 'MSBuild' -ErrorAction SilentlyContinue)
if ($mb.Count -gt 0) {
    $priv = ($mb | Measure-Object -Property PrivateMemorySize64 -Sum -ErrorAction SilentlyContinue).Sum
    $reclaimTotal += (MB $priv)
    $cands += [pscustomobject]@{
        项目 = 'MSBuild 编译节点'; 进程 = $mb.Count; 可回收MB = (MB $priv); 风险 = '低'
    }
}

# 2.2 重复的 Visual Studio 实例
$dv = @(Get-Process -Name 'devenv' -ErrorAction SilentlyContinue)
$dvNoWin = @()
if ($dv.Count -ge 2) {
    foreach ($p in $dv) {
        $t = $p.MainWindowTitle
        # 标题形如 "解决方案 - 文件.cs - Microsoft Visual Studio" 说明打开了具体文件
        $hasDoc = $t -match ' - .+\.(cs|csproj|sln|xaml|json|xml|md|py|cpp|h)\s*-\s*Microsoft Visual Studio'
        if (-not $hasDoc) { $dvNoWin += $p }
    }
    if ($dvNoWin.Count -gt 0) {
        $priv = ($dvNoWin | Measure-Object -Property PrivateMemorySize64 -Sum -ErrorAction SilentlyContinue).Sum
        $reclaimTotal += (MB $priv)
        $cands += [pscustomobject]@{
            项目 = '重复的 VS 实例'; 进程 = $dvNoWin.Count; 可回收MB = (MB $priv); 风险 = '中'
        }
    }
}

# 2.3 Joplin
$jp = @(Get-Process -Name 'Joplin' -ErrorAction SilentlyContinue)
if ($jp.Count -gt 0) {
    $priv = ($jp | Measure-Object -Property PrivateMemorySize64 -Sum -ErrorAction SilentlyContinue).Sum
    $reclaimTotal += (MB $priv)
    $win = @($jp | Where-Object { $_.MainWindowTitle })
    $cands += [pscustomobject]@{
        项目 = ('Joplin（{0} 进程，{1} 窗口）' -f $jp.Count, $win.Count)
        进程 = $jp.Count; 可回收MB = (MB $priv); 风险 = '低'
    }
}

# 2.4 后台常驻
$bgList = @(
    @{ Name = 'ToDesk';        Desc = 'ToDesk 远程控制' },
    @{ Name = 'Lertaro.App';   Desc = 'Lertaro' },
    @{ Name = 'localsend_app'; Desc = 'LocalSend 局域网传输' },
    @{ Name = 'wpscloudsvr';   Desc = 'WPS 云文档服务' },
    @{ Name = 'eudic';         Desc = '欧路词典' }
)
$bgFound = @()
foreach ($b in $bgList) {
    $ps = @(Get-Process -Name $b.Name -ErrorAction SilentlyContinue)
    if ($ps.Count -gt 0) {
        $priv = ($ps | Measure-Object -Property PrivateMemorySize64 -Sum -ErrorAction SilentlyContinue).Sum
        $bgFound += $b.Name
        $reclaimTotal += (MB $priv)
        $cands += [pscustomobject]@{
            项目 = $b.Desc; 进程 = $ps.Count; 可回收MB = (MB $priv); 风险 = '低'
        }
    }
}

if ($cands.Count -eq 0) {
    Say '  没有发现可回收项。' 'Green'
} else {
    Write-Host ('  {0,-34} {1,4} {2,10}  {3}' -f '项目', '进程', '可回收', '风险') -ForegroundColor DarkGray
    foreach ($c in $cands) {
        Write-Host ('  {0,-34} {1,4} {2,7:N0} MB  {3}' -f $c.项目, $c.进程, $c.可回收MB, $c.风险)
    }
    Write-Host ''
    Write-Host ''
    Write-Host '  风险：低 = 可直接结束（会按需重启）；中 = 有未保存内容风险，脚本不动手'
    Write-Host ''
    Write-Host ('  合计可回收约 {0:N0} MB（{1:N1} GB）' -f $reclaimTotal, ($reclaimTotal / 1024)) -ForegroundColor Yellow
    Write-Host ('  回收后已提交约 {0:N1} GB' -f ($commitUsedGB - $reclaimTotal / 1024)) -ForegroundColor Green
}

# ---------------- 3. 附注 ----------------
Head '四、需要你自己处理的两件事'
if ($dvNoWin.Count -gt 0) {
    foreach ($p in $dvNoWin) {
        Write-Host ('  · 重复的 VS 实例：PID {0}，标题「{1}」' -f $p.Id, $p.MainWindowTitle) -ForegroundColor Yellow
    }
    Say '    这个实例没有打开具体文件，多半是双击 .sln 多开了一个。'
    Say '    请手动确认它没有未保存的改动后关闭窗口 —— 脚本不会替你杀 VS。'
}
$cf = Get-PSDrive -Name C -ErrorAction SilentlyContinue
if ($cf -and $cf.Free -lt 20GB) {
    Write-Host ('  · C 盘只剩 {0:N1} GB，而页面文件占了 24.5 GB。' -f ($cf.Free / 1GB)) -ForegroundColor Yellow
    Say '    先加内存到 32 GB，再把页面文件压到 8 GB，C 盘能立刻多出 16 GB。'
    Say '    顺序不能反：现在压缩页面文件会让提交上限降到 24 GB 以下，直接触发内存不足。'
}

Head '五、结论'
if (-not $Apply) {
    Say '  这是演练模式，未做任何改动。' 'Yellow'
    Say '  确认清单无误后，加 -Apply 和对应开关再跑一次。'
} else {
    Say '  开始执行…' 'Cyan'
}

# ---------------- 4. 执行 ----------------
function Reclaim([string]$label) {
    $now = Get-CimInstance Win32_OperatingSystem
    $limit = [math]::Round($now.TotalVirtualMemorySize / 1MB, 2)
    $free = [math]::Round($now.FreeVirtualMemory / 1MB, 2)
    $used = [math]::Round($limit - $free, 2)
    Write-Host ('  [{0}] 已提交 {1:N2} GB（{2}%）' -f $label, $used, [math]::Round($used / $limit * 100, 0)) -ForegroundColor Green
}

if ($Apply -and $TrimMsBuild) {
    Head '结束空闲的 MSBuild 节点'
    $mb = @(Get-Process -Name 'MSBuild' -ErrorAction SilentlyContinue)
    if ($mb.Count -eq 0) {
        Say '  没有 MSBuild 进程。'
    } else {
        Say ('  找到 {0} 个，先测 5 秒 CPU 活动…' -f $mb.Count)
        $before = @{}
        foreach ($p in $mb) { try { $before[$p.Id] = $p.TotalProcessorTime.TotalSeconds } catch { $before[$p.Id] = 0 } }
        Start-Sleep -Seconds 5
        $busy = @()
        $idle = @()
        foreach ($p in $mb) {
            $cpu = 0
            try { $cpu = $p.TotalProcessorTime.TotalSeconds - $before[$p.Id] } catch {}
            if ($cpu -gt 0.1) { $busy += $p } else { $idle += $p }
        }
        if ($busy.Count -gt 0) {
            Say ('  有 {0} 个正在编译，整组跳过，避免打断编译。' -f $busy.Count) 'Red'
        } else {
            Say ('  {0} 个全部空闲，结束。' -f $idle.Count) 'Yellow'
            foreach ($p in $idle) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
                    Write-Host ('    PID {0} 结束失败：{1}' -f $p.Id, $_.Exception.Message) -ForegroundColor DarkYellow
                }
            }
            Start-Sleep -Seconds 2
            Reclaim 'MSBuild 已结束'
        }
    }
}

if ($Apply -and $QuitJoplin) {
    Head '结束 Joplin'
    $jp = @(Get-Process -Name 'Joplin' -ErrorAction SilentlyContinue)
    if ($jp.Count -eq 0) {
        Say '  Joplin 没有运行。'
    } else {
        $priv = MB (($jp | Measure-Object -Property PrivateMemorySize64 -Sum -ErrorAction SilentlyContinue).Sum)
        Say ('  {0} 个进程，{1:N0} MB。' -f $jp.Count, $priv) 'Yellow'
        foreach ($p in $jp) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
                Write-Host ('    PID {0} 失败：{1}' -f $p.Id, $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }
        Start-Sleep -Seconds 2
        Reclaim 'Joplin 已结束'
        Say '  下次启动会回到 3~5 个进程、约 400 MB。' 'DarkGray'
    }
}

if ($Apply -and $QuitBackground) {
    Head '结束闲置的后台常驻'
    foreach ($name in $bgFound) {
        $ps = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($ps.Count -eq 0) { continue }
        $priv = MB (($ps | Measure-Object -Property PrivateMemorySize64 -Sum -ErrorAction SilentlyContinue).Sum)
        Say ('  {0}：{1} 个进程，{2:N0} MB' -f $name, $ps.Count, $priv) 'Yellow'
        foreach ($p in $ps) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
                Write-Host ('    PID {0} 失败：{1}' -f $p.Id, $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }
    }
    Start-Sleep -Seconds 2
    Reclaim '后台常驻已结束'
}

if ($Apply) {
    Head '完成'
    Reclaim '最终'
    Say '  提示：进程被释放的提交额度会立刻归还，但物理内存要过一会儿才看到回升。' 'DarkGray'
}
