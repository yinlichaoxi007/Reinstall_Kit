#requires -Version 5.1
<#
    15-清空回收站.ps1  ——  清空回收站（全部盘或指定盘，覆盖所有用户的 SID 目录）
    ============================================================
    为什么不用 Explorer 的「清空回收站」：
      · shell API 每秒只能删十几个，17 万项要 8 小时
      · 这里直接按文件系统删，速度通常快百倍以上

    为什么不用 rd /s /q 整个 SID 目录：
      · 旧版临时脚本只写死了 -1001 一个 SID，删不到别的账户的目录
      · rd 整目录会碰 SID 目录本身的 ACL，个别项被占用时整条中断且无报告

    本脚本做法：
      1. 列出所有带回收站目录的本地盘，交互选择「全部盘（默认）」或某个盘符
      2. 枚举所选盘 <盘>:\$Recycle.Bin 下所有 SID 目录（当前账户 + 其他账户）
      3. 先数条目数给你确认（多盘输入 ALL、单盘输入大写盘符 二次确认）
      4. 逐条删除（$I 元数据文件 + $R 内容文件/目录），单行实时刷新：
         百分比 / 已删数 / 失败数 / 速率 / 当前正在删的项
      5. 失败项自动重试一遍；仍失败的列清单（通常是正被进程占用）
      6. 结束后重新枚举，报告「剩余 N 项」

    用法：
      powershell -ExecutionPolicy Bypass -File 15-清空回收站.ps1               # 交互选盘，回车 = 全部盘
      powershell -ExecutionPolicy Bypass -File 15-清空回收站.ps1 -DriveLetter D
      powershell -ExecutionPolicy Bypass -File 15-清空回收站.ps1 -DriveLetter D -WhatIf
      powershell -ExecutionPolicy Bypass -File 15-清空回收站.ps1 -NoConfirm   # 跳过选盘和删除确认（默认全部盘）

    需要：管理员权限（要删其他账户的 SID 目录）。脚本会自己请求 UAC。
#>
[CmdletBinding()]
param(
    [string]$DriveLetter = '',
    [switch]$WhatIf,
    [switch]$NoConfirm
)

$ErrorActionPreference = 'Continue'
# 不改 [Console]::OutputEncoding —— 中文控制台是 936，强改 UTF8 会乱码

# ---------------------------------------------------------------- 自提权
$wid = [Security.Principal.WindowsIdentity]::GetCurrent()
$wpr = New-Object Security.Principal.WindowsPrincipal($wid)
if (-not $wpr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "需要管理员权限（要删所有账户的回收站目录），正在请求 UAC ..." -ForegroundColor Yellow
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($DriveLetter) { $relaunch += @('-DriveLetter', $DriveLetter) }
    if ($WhatIf)    { $relaunch += '-WhatIf' }
    if ($NoConfirm) { $relaunch += '-NoConfirm' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs | Out-Null
        exit 0
    } catch {
        Write-Host "未获得管理员权限，已取消。" -ForegroundColor Red
        if ($Host.Name -match 'Console') { try { Read-Host '按回车键退出' | Out-Null } catch { } }
        exit 2
    }
}

# ---------------------------------------------------------------- 工具函数
function Write-ProgressLine {
    param([string]$Text)
    if ($Text.Length -gt 96) { $Text = $Text.Substring(0, 96) }
    $pad = [Math]::Max(0, 100 - $Text.Length)
    Write-Host ("`r" + $Text + (" " * $pad)) -NoNewline -ForegroundColor Gray
}

function Format-Els([TimeSpan]$ts) {
    return ("{0:00}:{1:00}" -f [int][Math]::Floor($ts.TotalMinutes), $ts.Seconds)
}

# 单条删除：先走 .NET 长路径 API，失败再退到 Remove-Item
# 返回 $null = 成功；字符串 = 失败原因
function Remove-OneItem {
    param([string]$Path, [bool]$IsDir)
    $long = '\\?\' + $Path
    try {
        if ($IsDir) { [System.IO.Directory]::Delete($long, $true) }
        else        { [System.IO.File]::Delete($long) }
        return $null
    } catch {
        try {
            if ($IsDir) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
            else        { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
            return $null
        } catch {
            return $_.Exception.Message
        }
    }
}

# 枚举某个 SID 目录的直接子项（$I 元数据 + $R 内容 + 子目录）
# 目录类型取枚举时已返回的 Attributes，不再对每个条目单独查一次属性：
# 三十多万条目时，逐条 Directory.Exists 在机械盘上要多花十几分钟
# -Drive：条目所属盘符，删除进度里用来区分是哪个盘
function Get-BinItems {
    param([string]$Dir, [string]$Label = '', [string]$Drive = '', [switch]$Quiet)
    $out = [System.Collections.Generic.List[object]]::new()
    $nextTick = 20000
    try {
        foreach ($e in [System.IO.DirectoryInfo]::new($Dir).EnumerateFileSystemInfos()) {
            $isDir = (($e.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            $out.Add([pscustomobject]@{ Drive = $Drive; Path = $e.FullName; IsDir = $isDir })
            if (-not $Quiet -and $out.Count -ge $nextTick) {
                $nextTick += 20000
                Write-ProgressLine ("      正在枚举 {0} … 已发现 {1} 项" -f $Label, $out.Count)
            }
        }
    } catch { }
    if (-not $Quiet -and $out.Count -ge 20000) {
        Write-ProgressLine ("      正在枚举 {0} … 完成，共 {1} 项" -f $Label, $out.Count)
    }
    return ,$out
}

# 枚举可清理的盘符：已就绪的本地固定盘/可移动盘，且存在 $Recycle.Bin 目录
# 返回：盘符数组（如 @('C','D')）
function Get-RecycleBinDrives {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        if ($d.DriveType -ne [System.IO.DriveType]::Fixed -and
            $d.DriveType -ne [System.IO.DriveType]::Removable) { continue }
        $bin = $d.Name.TrimEnd('\') + '\$Recycle.Bin'
        if ([System.IO.Directory]::Exists('\\?\' + $bin)) {
            $out.Add($d.Name.Substring(0, 1).ToUpperInvariant())
        }
    }
    return $out
}

# 交互选盘：列出全部盘和每个候选盘，回车 / 0 / ALL = 全部
# 参数 Candidates：候选盘符数组
# 返回：选中的盘符数组（选单个盘时也是数组）
function Select-RecycleBinDrives {
    param($Candidates)

    Write-Host ""
    Write-Host "  请选择要清空的回收站：" -ForegroundColor White
    Write-Host "    [0] 全部盘符（默认）"
    for ($k = 0; $k -lt $Candidates.Count; $k++) {
        Write-Host ("    [{0}] {1}:" -f ($k + 1), $Candidates[$k])
    }

    while ($true) {
        $ans = ''
        try { $ans = Read-Host "  输入序号或盘符（直接回车 = 全部）" } catch { $ans = '' }
        if ($null -eq $ans) { $ans = '' }
        $ans = $ans.Trim()

        if ($ans -eq '' -or $ans -eq '0' -or $ans -eq '全部' -or $ans.ToUpper() -eq 'ALL') {
            return @($Candidates)
        }
        $one = $ans.TrimEnd(':').ToUpper()
        if ($Candidates -contains $one) { return $one }
        if ($ans -match '^\d+$') {
            $idx = [int]$ans
            if ($idx -ge 1 -and $idx -le $Candidates.Count) { return $Candidates[$idx - 1] }
        }
        Write-Host "  输入无效：请输入 0、序号或盘符（如 D）。" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 开场
Write-Host ""
Write-Host ("=" * 68) -ForegroundColor Cyan
Write-Host "  清空回收站（文件系统直删，覆盖所有账户）" -ForegroundColor Cyan
Write-Host ("=" * 68) -ForegroundColor Cyan

$candidates = @(Get-RecycleBinDrives)
if ($candidates.Count -eq 0) {
    Write-Host '  没有找到任何回收站目录（本地盘都没有 $Recycle.Bin），无需清理。' -ForegroundColor Green
    if ($Host.Name -match 'Console') { try { Read-Host '按回车键退出' | Out-Null } catch { } }
    exit 0
}

# 确定目标盘：显式参数优先；-NoConfirm 时直接取全部盘；否则交互选择
if ($DriveLetter) {
    $want = $DriveLetter.Trim().TrimEnd(':').ToUpper()
    if ($candidates -notcontains $want) {
        Write-Host ("  [错误] {0} 盘没有可清理的回收站目录（或不是本地盘）。" -f $want) -ForegroundColor Red
        Write-Host ("  可清理的盘符：{0}" -f ($candidates -join '、')) -ForegroundColor Yellow
        if ($Host.Name -match 'Console') { try { Read-Host '按回车键退出' | Out-Null } catch { } }
        exit 1
    }
    $letters = @($want)
} elseif ($NoConfirm) {
    $letters = @($candidates)
} else {
    $letters = @(Select-RecycleBinDrives -Candidates $candidates)
}

# ---------------------------------------------------------------- 枚举
$targets = [System.Collections.Generic.List[object]]::new()
$allItems = [System.Collections.Generic.List[object]]::new()
foreach ($letter in $letters) {
    $root = $letter + ':\$Recycle.Bin'
    $sidDirs = @()
    try {
        $sidDirs = @([System.IO.Directory]::EnumerateDirectories('\\?\' + $root) |
                     ForEach-Object { $_.Substring(4) })
    } catch { }

    if ($sidDirs.Count -eq 0) {
        Write-Host ("  {0}: 没有 SID 目录，回收站本来就是空的。" -f $letter) -ForegroundColor Green
        continue
    }

    Write-Host ""
    Write-Host ("  --- {0}: 找到 {1} 个账户的回收站目录 ---" -f $letter, $sidDirs.Count) -ForegroundColor Cyan
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($sd in $sidDirs) {
        $who = Split-Path $sd -Leaf
        $swEnum = [System.Diagnostics.Stopwatch]::StartNew()
        $part = Get-BinItems -Dir $sd -Label $who -Drive $letter
        $items.AddRange($part)
        Write-ProgressLine ("    {0,-52} {1,8} 项  ({2:0.0}s)" -f $who, $part.Count, $swEnum.Elapsed.TotalSeconds)
    }

    if ($items.Count -eq 0) {
        Write-Host ("  {0}: 回收站已经是空的。" -f $letter) -ForegroundColor Green
        continue
    }

    [void]$targets.Add([pscustomobject]@{ Letter = $letter; SidDirs = $sidDirs; Items = $items })
    $allItems.AddRange($items)
}

if ($allItems.Count -eq 0) {
    Write-Host ""
    Write-Host "  所选盘的回收站已经是空的。" -ForegroundColor Green
    if ($Host.Name -match 'Console') { try { Read-Host '按回车键退出' | Out-Null } catch { } }
    exit 0
}

$summary = ($targets | ForEach-Object { "{0}: {1} 项" -f $_.Letter, $_.Items.Count }) -join '，'
Write-Host ""
Write-Host ("  共 {0} 项待删除（{1}）。" -f $allItems.Count, $summary) -ForegroundColor White
if ($WhatIf) {
    Write-Host "  [演练] 不做任何删除。去掉 -WhatIf 真正执行。" -ForegroundColor Yellow
    if ($Host.Name -match 'Console') { try { Read-Host '按回车键退出' | Out-Null } catch { } }
    exit 0
}

if (-not $NoConfirm) {
    Write-Host ""
    Write-Host "  !!! 这一步不可恢复：回收站里的东西删了就找不回来。" -ForegroundColor Yellow
    if ($targets.Count -eq 1) {
        $expect = $targets[0].Letter
        $prompt = "  确认清空 {0} 盘回收站？输入大写盘符 {0} 继续" -f $expect
    } else {
        $expect = 'ALL'
        $prompt = "  确认清空以上 {0} 个盘的回收站？输入 ALL 继续" -f $targets.Count
    }
    $ans = $null
    try { $ans = Read-Host $prompt } catch { $ans = $null }
    $ok = $false
    if ($null -ne $ans) {
        if ($targets.Count -eq 1) { $ok = ($ans.Trim() -eq $expect) }
        else { $ok = ($ans.Trim().ToUpper() -eq $expect) }
    }
    if (-not $ok) {
        Write-Host "  输入不一致，已取消（未做任何修改）。" -ForegroundColor Yellow
        if ($Host.Name -match 'Console') { try { Read-Host '按回车键退出' | Out-Null } catch { } }
        exit 1
    }
}

# ---------------------------------------------------------------- 第一遍删除
Write-Host ""
Write-Host "--- 开始删除 ---" -ForegroundColor Cyan
$swAll = [System.Diagnostics.Stopwatch]::StartNew()
$failedList = New-Object System.Collections.ArrayList
$total = $allItems.Count
$i = 0
$fails = 0
$lastShow = [DateTime]::MinValue

foreach ($item in $allItems) {
    $i++
    $err = Remove-OneItem -Path $item.Path -IsDir $item.IsDir
    if ($err) {
        $fails++
        [void]$failedList.Add([pscustomobject]@{ Path = $item.Path; Error = $err })
    }
    if (((Get-Date) - $lastShow).TotalMilliseconds -ge 200 -or $i -eq $total) {
        $lastShow = Get-Date
        $pct = [Math]::Round($i * 100.0 / $total, 1)
        $rate = [int]($i / [Math]::Max(0.5, $swAll.Elapsed.TotalSeconds))
        $cur = $item.Drive + ':' + (Split-Path $item.Path -Leaf)
        Write-ProgressLine ("  {0}%  已删 {1}/{2}  失败 {3}  {4}/s  已用 {5}  当前: {6}" -f `
            $pct, $i, $total, $fails, $rate, (Format-Els $swAll.Elapsed), $cur)
    }
}
Write-Host ""
Write-Host ("  第一遍完成：成功 {0} / 失败 {1}，用时 {2}" -f `
    ($total - $failedList.Count), $failedList.Count, (Format-Els $swAll.Elapsed)) -ForegroundColor Cyan

# ---------------------------------------------------------------- 失败重试
if ($failedList.Count -gt 0) {
    Write-Host ""
    Write-Host "--- 失败项重试（等 1 秒让占用释放）---" -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    $retryList = New-Object System.Collections.ArrayList
    $j = 0
    foreach ($f in $failedList) {
        $j++
        $isDir = [System.IO.Directory]::Exists('\\?\' + $f.Path)
        $err = Remove-OneItem -Path $f.Path -IsDir $isDir
        Write-ProgressLine ("  重试 {0}/{1} ..." -f $j, $failedList.Count)
        if ($err) { [void]$retryList.Add([pscustomobject]@{ Path = $f.Path; Error = $err }) }
    }
    Write-Host ""
    $failedList = $retryList
    if ($failedList.Count -gt 0) {
        Write-Host ("  重试后仍失败 {0} 项（通常是正被进程占用，重启后再跑一次本脚本即可）：" -f $failedList.Count) -ForegroundColor Red
        foreach ($f in ($failedList | Select-Object -First 10)) {
            Write-Host ("      " + (Split-Path $f.Path -Leaf) + "  —— " + $f.Error) -ForegroundColor DarkYellow
        }
        if ($failedList.Count -gt 10) { Write-Host ("      …… 其余 {0} 项略" -f ($failedList.Count - 10)) }
    } else {
        Write-Host "  重试后全部删除成功。" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------- 收尾核对
Write-Host ""
Write-Host "--- 收尾核对 ---" -ForegroundColor Cyan
$left = 0
foreach ($t in $targets) {
    $n = 0
    foreach ($sd in $t.SidDirs) { $n += (Get-BinItems -Dir $sd -Quiet).Count }
    $left += $n
    if ($n -eq 0) {
        Write-Host ("  [OK] {0}: 回收站已清空。" -f $t.Letter) -ForegroundColor Green
    } else {
        Write-Host ("  [提示] {0}: 还剩 {1} 项没删掉。" -f $t.Letter, $n) -ForegroundColor Yellow
    }
}
if ($left -eq 0) {
    Write-Host ("  清空完成，总用时 {0}。" -f (Format-Els $swAll.Elapsed)) -ForegroundColor Green
} else {
    Write-Host ("  共剩 {0} 项（见上面的失败清单），重启后再跑一次本脚本即可。" -f $left) -ForegroundColor Yellow
}

if ($Host.Name -match 'Console') { try { Read-Host '按回车键退出' | Out-Null } catch { } }
if ($left -gt 0) { exit 1 } else { exit 0 }
