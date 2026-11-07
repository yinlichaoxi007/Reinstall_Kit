#requires -Version 5.1
<#
    16-校验链接.ps1  ——  启动程序前的最后一道校验
    ============================================================
    解决什么问题：
      2-重建链接.ps1 只检查「这个位置是不是链接」，
      但不检查「链接指得对不对」「指过去之后数据读不读得到」。
      链接指错的后果是静默的：Joplin 会在 C 盘建一个空库，
      你以为笔记丢了；VSCode 会把插件写到 C 盘，重装又没了。

    本脚本检查三层：
      [1] 37 条链接：存在 / 是 junction / 指向与 links.csv 一致 / 目标可达
      [2] 关键数据深度校验：Joplin 的库、附件、设置、插件是否真的能读到
      [3] 危险残留：C 盘是否已生成过实体 profile、是否有上次改名留下的 .local-*

    用法：
      powershell -ExecutionPolicy Bypass -File scripts\16-校验链接.ps1
      powershell -ExecutionPolicy Bypass -File scripts\16-校验链接.ps1 -Fix     # 自动重建后复验
      powershell -ExecutionPolicy Bypass -File scripts\16-校验链接.ps1 -SelfTest # 验证检测逻辑本身有效

    退出码：0 = 全部通过；1 = 有 FAIL；2 = 环境问题（找不到清单等）
    不需要管理员权限。
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$SelfTest,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
# 不要改 [Console]::OutputEncoding —— 中文控制台是 936，强改 UTF8 会乱码

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot   = Split-Path -Parent $scriptDir

$csvCandidates = @(
    (Join-Path $kitRoot 'links.csv'),
    (Join-Path $scriptDir 'links.csv'),
    'D:\Reinstall_Kit\links.csv'
)
$csvPath = $null
foreach ($c in $csvCandidates) { if (Test-Path -LiteralPath $c) { $csvPath = $c; break } }

function Say {
    param([string]$Msg, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Msg -ForegroundColor $Color }
}

$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Level, [string]$Name, [string]$Detail)
    [void]$script:Results.Add([pscustomobject]@{
        Level  = $Level
        Name   = $Name
        Detail = $Detail
    })
}

function Normalize-Path {
    param([string]$P)
    if (-not $P) { return '' }
    $s = $P.Trim()
    if ($s.StartsWith('\\?\')) { $s = $s.Substring(4) }
    return $s.TrimEnd('\').ToLowerInvariant()
}

function Get-LinkTargetOf {
    param($Item)
    try {
        if ($Item.PSObject.Properties['Target'] -and $Item.Target) { return [string]$Item.Target }
    } catch {}
    try {
        if ($Item.PSObject.Properties['LinkTarget'] -and $Item.LinkTarget) { return [string]$Item.LinkTarget }
    } catch {}
    return $null
}

# ---------------------------------------------------------------- 第 1 层
function Test-AllLinks {
    param($Rows)

    foreach ($row in $Rows) {
        $rel    = [string]$row.rel
        $expect = [string]$row.target
        $link   = Join-Path $env:USERPROFILE $rel

        if (-not (Test-Path -LiteralPath $link)) {
            Add-Result 'FAIL' $rel '链接不存在（程序会在这里新建实体目录，数据写到 C 盘）'
            continue
        }

        $item = Get-Item -LiteralPath $link -Force
        $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if (-not $isLink) {
            $kind = if ($item.PSIsContainer) { '普通目录' } else { '普通文件' }
            Add-Result 'FAIL' $rel ("不是链接，是$kind（上次改名/新建过，数据可能分叉）")
            continue
        }

        $cur = Get-LinkTargetOf $item
        if (-not $cur) {
            Add-Result 'WARN' $rel '是链接但读不出指向（权限或非 junction 类型）'
            continue
        }

        if ((Normalize-Path $cur) -ne (Normalize-Path $expect)) {
            Add-Result 'FAIL' $rel ("指向错误：实际 {0} / 应为 {1}" -f $cur, $expect)
            continue
        }

        if (-not (Test-Path -LiteralPath $expect)) {
            Add-Result 'FAIL' $rel ("链接指向 {0}，但该路径当前不可达（数据盘没挂上？）" -f $expect)
            continue
        }

        Add-Result 'OK' $rel $expect
    }
}

# ---------------------------------------------------------------- 第 2 层
function Test-JoplinProfile {
    $profRel = '.config\joplin-desktop'
    $prof    = Join-Path $env:USERPROFILE $profRel

    if (-not (Test-Path -LiteralPath $prof)) {
        Add-Result 'FAIL' 'Joplin 库' 'profile 目录不存在，笔记数据不可达'
        return
    }

    # --- 数据库 ---
    $db = Join-Path $prof 'database.sqlite'
    if (-not (Test-Path -LiteralPath $db)) {
        Add-Result 'FAIL' 'Joplin 库' 'database.sqlite 不存在（笔记正文全在这里）'
    } else {
        $fi = Get-Item -LiteralPath $db -Force
        $mb = [math]::Round($fi.Length / 1MB, 1)
        if ($fi.Length -lt 50MB) {
            Add-Result 'FAIL' 'Joplin 库' ("database.sqlite 只有 {0} MB，明显不对（应约 183 MB）" -f $mb)
        } else {
            # 文件头必须是 SQLite。Joplin 运行时文件被占用，
            # 必须以「共享读写」方式打开，否则会误判成文件损坏。
            $sigOk = $false
            $readErr = ''
            try {
                $fs = [System.IO.File]::Open(
                    $db,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                $buf = New-Object 'System.Byte[]' 16
                $n = $fs.Read($buf, 0, 16)
                $fs.Dispose()
                if ($n -ge 15) {
                    $sig = [System.Text.Encoding]::ASCII.GetString($buf, 0, 15)
                    $sigOk = ($sig -eq 'SQLite format 3')
                } else {
                    $readErr = ("只读到 {0} 字节" -f $n)
                }
            } catch {
                $readErr = $_.Exception.Message
            }

            if ($sigOk) {
                Add-Result 'OK' 'Joplin 库' ("database.sqlite {0} MB，文件头正确" -f $mb)
            } elseif ($readErr) {
                Add-Result 'WARN' 'Joplin 库' ("database.sqlite {0} MB，当前读不到文件头（{1}）；完全退出 Joplin 后再验一次" -f $mb, $readErr)
            } else {
                Add-Result 'FAIL' 'Joplin 库' ("database.sqlite {0} MB，但文件头不是 SQLite（可能拷坏了）" -f $mb)
            }
        }
    }

    # --- 设置 ---
    $st = Join-Path $prof 'settings.json'
    if (-not (Test-Path -LiteralPath $st)) {
        Add-Result 'FAIL' 'Joplin 设置' 'settings.json 不存在（同步目标等配置会丢）'
    } else {
        try {
            $txt = Get-Content -LiteralPath $st -Raw -Encoding UTF8
            $obj = $txt | ConvertFrom-Json
            Add-Result 'OK' 'Joplin 设置' 'settings.json 可解析'
        } catch {
            Add-Result 'FAIL' 'Joplin 设置' ('settings.json 解析失败：' + $_.Exception.Message)
        }
    }

    # --- 附件目录（只验证可达且非空，不数 3 万个文件，避免机械盘上卡几十秒）---
    $res = Join-Path $prof 'resources'
    if (-not (Test-Path -LiteralPath $res)) {
        Add-Result 'FAIL' 'Joplin 附件' 'resources\ 不存在（图片/PDF 会显示不出来）'
    } else {
        $first = $null
        try {
            $e = [System.IO.Directory]::EnumerateFiles($res, '*', [System.IO.SearchOption]::TopDirectoryOnly).GetEnumerator()
            if ($e.MoveNext()) { $first = $e.Current }
            $e.Dispose()
        } catch {}
        if ($first) {
            Add-Result 'OK' 'Joplin 附件' 'resources\ 可达且非空'
        } else {
            Add-Result 'FAIL' 'Joplin 附件' 'resources\ 是空的（应该指向 D 盘那份 4.58 GB）'
        }
    }

    # --- 插件 ---
    $pl = Join-Path $prof 'plugins'
    if (Test-Path -LiteralPath $pl) {
        $n = @(Get-ChildItem -LiteralPath $pl -File -Force -ErrorAction SilentlyContinue).Count
        if ($n -ge 10) {
            Add-Result 'OK' 'Joplin 插件' ("plugins\ {0} 个文件" -f $n)
        } else {
            Add-Result 'WARN' 'Joplin 插件' ("plugins\ 只有 {0} 个文件（重装前是 11 个）" -f $n)
        }
    } else {
        Add-Result 'WARN' 'Joplin 插件' 'plugins\ 不存在（将没有插件，可从备份补）'
    }

    # --- 上次未正常退出留下的 WAL ---
    foreach ($suffix in @('-wal', '-shm')) {
        $w = $db + $suffix
        if (Test-Path -LiteralPath $w) {
            $wmb = [math]::Round((Get-Item -LiteralPath $w -Force).Length / 1MB, 1)
            Add-Result 'WARN' 'Joplin 库' ("存在 database.sqlite{0}（{1} MB），说明上次没正常退出；先开一次 Joplin 让它归并再备份" -f $suffix, $wmb)
        }
    }
}

# ---------------------------------------------------------------- 第 3 层
function Test-Residue {
    $configDir = Join-Path $env:USERPROFILE '.config'
    if (Test-Path -LiteralPath $configDir) {
        $left = @(Get-ChildItem -LiteralPath $configDir -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like 'joplin-desktop.local-*' -or $_.Name -like 'joplin-desktop.bak*' })
        foreach ($x in $left) {
            Add-Result 'WARN' 'C 盘残留' ("{0}（上次改名留下的，确认无用后删掉，别让它占空间）" -f $x.Name)
        }
    }

    # 装过并跑过 Joplin 但链接没建好的典型迹象
    $appDir = Join-Path $env:LOCALAPPDATA 'Programs\Joplin'
    if ((Test-Path -LiteralPath $appDir) -and -not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.config\joplin-desktop'))) {
        Add-Result 'FAIL' '启动顺序' 'Joplin 已安装但 profile 链接不存在，一旦启动就会在 C 盘建空库'
    }
}

# ---------------------------------------------------------------- 报告
function Invoke-AllChecks {
    param($Rows)
    $script:Results.Clear()
    Test-AllLinks $Rows
    Test-JoplinProfile
    Test-Residue

    $fail = @($script:Results | Where-Object { $_.Level -eq 'FAIL' })
    $warn = @($script:Results | Where-Object { $_.Level -eq 'WARN' })
    $ok   = @($script:Results | Where-Object { $_.Level -eq 'OK' })

    Say ""
    Say "=== 链接校验 ===" 'Cyan'
    Say ("用户: {0}" -f $env:USERPROFILE) 'DarkGray'
    Say ("清单: {0}" -f $csvPath) 'DarkGray'

    Say ""
    Say "--- 通过的 ---" 'Cyan'
    foreach ($r in $ok) {
        Say ("  OK    {0}" -f $r.Name) 'Green'
        if (-not $Quiet) { Say ("        {0}" -f $r.Detail) 'DarkGray' }
    }
    if ($ok.Count -eq 0) { Say "  （无）" 'DarkGray' }

    if ($warn.Count -gt 0) {
        Say ""
        Say "--- 提醒（不阻塞）---" 'Cyan'
        foreach ($r in $warn) {
            Say ("  WARN  {0}" -f $r.Name) 'Yellow'
            Say ("        {0}" -f $r.Detail) 'DarkGray'
        }
    }

    if ($fail.Count -gt 0) {
        Say ""
        Say "--- 必须处理 ---" 'Cyan'
        foreach ($r in $fail) {
            Say ("  FAIL  {0}" -f $r.Name) 'Red'
            Say ("        {0}" -f $r.Detail) 'DarkGray'
        }
    }

    Say ""
    Say ("=== 结论：通过 {0} / 提醒 {1} / 失败 {2} ===" -f $ok.Count, $warn.Count, $fail.Count) `
        $(if ($fail.Count -gt 0) { 'Red' } else { 'Green' })

    return [pscustomobject]@{
        Ok   = $ok.Count
        Warn = $warn.Count
        Fail = $fail.Count
    }
}

# ---------------------------------------------------------------- 主流程
if (-not $csvPath) {
    Say "找不到 links.csv，无法校验。已尝试：" 'Red'
    foreach ($c in $csvCandidates) { Say ("  " + $c) 'DarkGray' }
    exit 2
}

$rows = @((Get-Content -LiteralPath $csvPath -Encoding UTF8 -Raw) | ConvertFrom-Csv)
if ($rows.Count -eq 0) {
    Say "links.csv 是空的，无法校验。" 'Red'
    exit 2
}

# 自检模式：故意篡改第一条的期望指向，验证检测逻辑真的会报错
if ($SelfTest) {
    Say "【自检模式】把第一条的期望指向改成不存在的路径，应当被判定为 FAIL" 'Magenta'
    $rows[0].target = 'X:\__selftest_must_fail__'
}

$summary = Invoke-AllChecks $rows

if ($SelfTest) {
    $hit = @($script:Results | Where-Object { $_.Level -eq 'FAIL' -and $_.Name -eq $rows[0].rel })
    Say ""
    if ($hit.Count -gt 0) {
        Say "自检结果：检测逻辑有效（成功抓到被篡改的那条）" 'Green'
        exit 0
    }
    Say "自检结果：检测逻辑失效（篡改后仍判为通过），请检查 Test-AllLinks" 'Red'
    exit 1
}

if ($summary.Fail -gt 0 -and $Fix) {
    Say ""
    Say "--- 发现 $($summary.Fail) 项失败，自动调用 2-重建链接.ps1 修复 ---" 'Yellow'
    $rebuild = Join-Path $scriptDir '2-重建链接.ps1'
    if (Test-Path -LiteralPath $rebuild) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $rebuild
        Say ""
        Say "--- 修复完成，重新校验 ---" 'Yellow'
        $rows2 = @((Get-Content -LiteralPath $csvPath -Encoding UTF8 -Raw) | ConvertFrom-Csv)
        $summary = Invoke-AllChecks $rows2
    } else {
        Say ("找不到 {0}，无法自动修复" -f $rebuild) 'Red'
    }
}

if ($summary.Fail -eq 0) {
    Say ""
    Say "链接与数据都就位，现在可以安装并启动程序了。" 'Green'
    Say "（Joplin 首次启动前请再确认一眼上面的 OK 行包含「Joplin 库」）" 'DarkGray'
    exit 0
}

Say ""
Say "有 $($summary.Fail) 项失败，先别装、别启动程序。" 'Red'
Say "  自动修复：powershell -ExecutionPolicy Bypass -File scripts\16-校验链接.ps1 -Fix" 'Yellow'
exit 1
