#requires -Version 5.1
<#
    16-扫描链接.ps1 —— 扫描迁移链接并维护 links.csv
    ============================================================
    解决什么问题：
      links.csv 一直靠手写。新增工具把数据迁到 D 盘并做成 junction 后，
      很容易忘记登记，换机重装时链接就会漏建，程序会在 C 盘重新生成实体目录。

    本脚本做三件事：
      [1] 按 links.csv 逐条校验：存在 / 是链接 / 指向正确 / 目标可达
      [2] 扫描用户目录，找出「指向迁移根目录、但清单里没有」的链接
      [3] -Record 时把选中的候选追加进 links.csv（只写清单，不动任何数据）

    用法：
      powershell -ExecutionPolicy Bypass -File scripts\16-扫描链接.ps1
      powershell -ExecutionPolicy Bypass -File scripts\16-扫描链接.ps1 -Record
      powershell -ExecutionPolicy Bypass -File scripts\16-扫描链接.ps1 -SelfTest

    退出码：0 = 正常；1 = 写入失败或自检失败；2 = 环境问题（缺配置/缺清单）
    不需要管理员权限。
#>
[CmdletBinding()]
param(
    [switch]$Record,
    [switch]$SelfTest,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$scriptDir   = $PSScriptRoot
$kitRoot     = Split-Path -Parent $scriptDir
$userProfile = [Environment]::GetFolderPath('UserProfile')

function Say {
    param([string]$Msg, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Msg -ForegroundColor $Color }
}

# ---------------------------------------------------------------- 纯函数
function Normalize-Path {
    param([string]$P)
    if (-not $P) { return '' }
    $s = $P.Trim()
    if ($s.StartsWith('\\?\')) { $s = $s.Substring(4) }
    return $s.TrimEnd('\').ToLowerInvariant()
}

function Test-UnderRoot {
    <# 判断路径是否位于根目录之下（大小写不敏感，避免 foo 误匹配 foobar） #>
    param([string]$Path, [string]$Root)
    $p = (Normalize-Path $Path).TrimEnd('\')
    $r = (Normalize-Path $Root).TrimEnd('\')
    if (-not $p -or -not $r) { return $false }
    return ($p -eq $r) -or $p.StartsWith($r + '\')
}

function ConvertTo-TokenTarget {
    <# 把迁移根目录开头的实际路径换成 %MIGROOT% 占位，避免把本机路径写进仓库 #>
    param([string]$Target, [string]$Root)
    $t = $Target.TrimEnd('\')
    $r = $Root.TrimEnd('\')
    if (Test-UnderRoot $t $r) {
        $tail = $t.Substring($r.Length).TrimStart('\')
        if ($tail) { return '%MIGROOT%\' + $tail }
        return '%MIGROOT%'
    }
    return $t
}

function Expand-Target {
    param([string]$Target, [string]$Root)
    $t = $Target.Replace('%MIGROOT%', $Root)
    return [Environment]::ExpandEnvironmentVariables($t)
}

function Format-CsvField {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value -match '[",\r\n]') { return '"' + $Value.Replace('"', '""') + '"' }
    return $Value
}

function ConvertFrom-Selection {
    <# 解析 1,3,5 / 1-5 / a；返回去重升序数组；非法输入抛异常 #>
    param([string]$Text, [int]$Count)
    $s = $Text.Trim().ToLowerInvariant()
    if (-not $s) { return @() }
    if ($s -eq 'a') { return @(1..$Count) }
    $picked = New-Object System.Collections.Generic.SortedSet[int]
    foreach ($part in ($s.Replace('，', ',') -split ',')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        if ($p -match '^(\d+)-(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            if ($lo -gt $hi) { $tmp = $lo; $lo = $hi; $hi = $tmp }
            for ($i = $lo; $i -le $hi; $i++) { [void]$picked.Add($i) }
        }
        elseif ($p -match '^\d+$') {
            [void]$picked.Add([int]$p)
        }
        else {
            throw "无法识别：$p"
        }
    }
    foreach ($n in $picked) {
        if ($n -lt 1 -or $n -gt $Count) { throw "编号超出范围：$n" }
    }
    return @($picked)
}

function Get-LinkTargetOf {
    <# 读取 junction/symlink 的指向；读不出时返回 $null #>
    param([string]$Path)
    $item = $null
    try { $item = Get-Item -LiteralPath $Path -Force } catch { return $null }
    try {
        if ($item.PSObject.Properties['Target'] -and $item.Target) {
            $t = $item.Target
            if ($t -is [array]) { $t = $t[0] }
            return [string]$t
        }
    } catch {}
    try {
        if ($item.PSObject.Properties['LinkTarget'] -and $item.LinkTarget) {
            return [string]$item.LinkTarget
        }
    } catch {}
    return $null
}

$script:SelfFail = 0
function Assert-Case {
    param([string]$Name, [bool]$Cond)
    if ($Cond) {
        Write-Host ("  [PASS] " + $Name) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] " + $Name) -ForegroundColor Red
        $script:SelfFail++
    }
}

# ---------------------------------------------------------------- 自检
if ($SelfTest) {
    Write-Head "16-扫描链接 · 自检"
    $root = 'D:\migration\C\Users\tester'
    Assert-Case '根目录下的路径转成 %MIGROOT% 占位' ((ConvertTo-TokenTarget "$root\AppData\Local" $root) -eq '%MIGROOT%\AppData\Local')
    Assert-Case '根目录本身转成 %MIGROOT%' ((ConvertTo-TokenTarget $root $root) -eq '%MIGROOT%')
    Assert-Case '非迁移根目标保持原样' ((ConvertTo-TokenTarget 'C:\Users\tester\AppData' $root) -eq 'C:\Users\tester\AppData')
    Assert-Case '前缀相同但不同目录不误判' (-not (Test-UnderRoot "$root-other\X" $root))
    Assert-Case '路径比较大小写不敏感' (Test-UnderRoot ($root.ToUpperInvariant() + '\X') $root)
    Assert-Case '选择 1-3,5 解析正确' (((ConvertFrom-Selection '1-3,5' 5) -join ',') -eq '1,2,3,5')
    Assert-Case '选择 a 解析为全部' (((ConvertFrom-Selection 'a' 3) -join ',') -eq '1,2,3')
    Assert-Case '重复编号自动去重' (((ConvertFrom-Selection '2,2,1' 3) -join ',') -eq '1,2')
    $bad = $false
    try { $null = ConvertFrom-Selection '0' 3 } catch { $bad = $true }
    Assert-Case '越界编号被拒绝' $bad
    Assert-Case 'CSV 字段含逗号时加引号' ((Format-CsvField 'a,b') -eq '"a,b"')
    Assert-Case 'CSV 字段含引号时转义' ((Format-CsvField 'a"b') -eq '"a""b"')
    Write-Host ""
    if ($script:SelfFail -eq 0) {
        Write-Host " 自检结果：全部通过" -ForegroundColor Green
        exit 0
    }
    Write-Host (" 自检结果：{0} 项失败" -f $script:SelfFail) -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 环境
$scanCfgPath = Join-Path $kitRoot 'links.scan.json'
if (-not (Test-Path -LiteralPath $scanCfgPath)) {
    Write-Err "找不到扫描配置：$scanCfgPath"
    exit 2
}
try {
    $scanCfg = Get-Content -LiteralPath $scanCfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
}
catch {
    Write-Err "扫描配置解析失败：$($_.Exception.Message)"
    exit 2
}
if ($scanCfg.migrationRoot) { $MigrationRoot = [string]$scanCfg.migrationRoot }
if (-not (Assert-MigrationRoot)) { exit 2 }
$maxDepth = 4
if ($scanCfg.maxDepth) { $maxDepth = [int]$scanCfg.maxDepth }
$roots = @($scanCfg.roots | Where-Object { $_ })
if ($roots.Count -eq 0) { $roots = @('%USERPROFILE%') }
$exclude = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in @($scanCfg.excludeDirs)) {
    if ($e) { [void]$exclude.Add(([string]$e).Trim('\')) }
}
$ignorePatterns = @()
foreach ($pat in @($scanCfg.ignoreRelPatterns)) {
    if ($pat) { $ignorePatterns += [regex]::new([string]$pat) }
}

$csvCandidates = @(
    (Join-Path $kitRoot 'links.csv'),
    (Join-Path $scriptDir 'links.csv'),
    'D:\Reinstall_Kit\links.csv'
)
$csvPath = $null
foreach ($c in $csvCandidates) { if (Test-Path -LiteralPath $c) { $csvPath = $c; break } }
if (-not $csvPath) {
    Write-Err "找不到 links.csv，已尝试：`n$($csvCandidates -join "`n")"
    exit 2
}

$logFile = Start-KitLog '16-扫描链接'
$exitCode = 0
try {
    Write-Head "16-扫描链接"
    Write-Info "  用户目录 : $userProfile"
    Write-Info "  迁移根   : $MigrationRoot"
    Write-Info "  链接清单 : $csvPath"
    Write-Info "  扫描配置 : $scanCfgPath"

    # 用 Get-Content -Encoding UTF8 + ConvertFrom-Csv，避免 PS 5.1 下 Import-Csv 编码差异
    $rows = @((Get-Content -LiteralPath $csvPath -Encoding UTF8 -Raw) | ConvertFrom-Csv)
    $csvRels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        $rel = [string]$row.rel
        if ($rel) { [void]$csvRels.Add($rel.Trim('\')) }
    }

    # ---------------- 第 1 部分：按清单逐条校验
    Write-Step "清单校验（$($rows.Count) 条）"
    $okCount = 0
    $failCount = 0
    $failItems = New-Object System.Collections.ArrayList

    foreach ($row in $rows) {
        $rel = [string]$row.rel
        if (-not $rel) { continue }
        $link    = Join-Path $userProfile $rel
        $expect  = Expand-Target ([string]$row.target) $MigrationRoot
        $problem = ''

        if (-not (Test-Path -LiteralPath $link)) {
            $problem = '链接不存在'
        }
        else {
            $item = Get-Item -LiteralPath $link -Force
            $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if (-not $isLink) {
                $kind = if ($item.PSIsContainer) { '普通目录' } else { '普通文件' }
                $problem = "不是链接，是$kind"
            }
            else {
                $cur = Get-LinkTargetOf $link
                if (-not $cur) {
                    $problem = '是链接但读不出指向'
                }
                elseif ((Normalize-Path $cur) -ne (Normalize-Path $expect)) {
                    $problem = "指向错误：实际 $cur / 应为 $expect"
                }
                elseif (-not (Test-Path -LiteralPath $expect)) {
                    $problem = "目标不可达：$expect"
                }
            }
        }

        if ($problem) {
            $failCount++
            [void]$failItems.Add([pscustomobject]@{ Rel = $rel; Problem = $problem })
        }
        else {
            $okCount++
        }
    }

    Write-Ok "正常：$okCount 条"
    if ($failCount -gt 0) {
        Write-Warn "异常：$failCount 条"
        foreach ($f in $failItems) {
            Say ("   [异常] {0}  ——  {1}" -f $f.Rel, $f.Problem) 'Yellow'
        }
        Say "   可用 08-校验链接.ps1 -Fix 自动重建，或手工核对 links.csv" 'DarkGray'
    }

    # ---------------- 第 2 部分：扫描未记录的迁移链接
    Write-Step "扫描用户目录（深度 $maxDepth）"
    function Get-ReparseDirectories {
        <# 广度优先枚举目录；遇到重解析点只记录、不深入；exclude 目录不再向下扫描 #>
        param([string]$RootPath, [int]$Depth)
        $result = New-Object System.Collections.ArrayList
        $rootFull = $RootPath.TrimEnd('\')
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([pscustomobject]@{ Path = $rootFull; Level = 0 })
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            $children = $null
            try { $children = [System.IO.Directory]::GetDirectories($cur.Path) } catch { continue }
            foreach ($child in $children) {
                $di = $null
                try { $di = New-Object System.IO.DirectoryInfo($child) } catch { continue }
                $isLink = [bool]($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
                if ($isLink) {
                    [void]$result.Add($child)
                    continue
                }
                if ($cur.Level + 1 -ge $Depth) { continue }
                $rel = ''
                if (Test-UnderRoot $child $rootFull) {
                    $rel = $child.Substring($rootFull.Length).TrimStart('\')
                }
                if ($rel -and $exclude.Contains($rel)) { continue }
                $queue.Enqueue([pscustomobject]@{ Path = $child; Level = $cur.Level + 1 })
            }
        }
        return $result
    }

    $migrationLinks = New-Object System.Collections.ArrayList
    $otherLinkCount = 0
    $ignoredCount = 0
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $roots) {
        $rootPath = [Environment]::ExpandEnvironmentVariables([string]$r)
        if (-not (Test-Path -LiteralPath $rootPath)) {
            Write-Warn "扫描根不存在：$rootPath"
            continue
        }
        Write-Info "  扫描 $rootPath ..."
        foreach ($p in (Get-ReparseDirectories $rootPath $maxDepth)) {
            if (-not (Test-UnderRoot $p $userProfile)) { continue }
            $rel = $p.Substring($userProfile.TrimEnd('\').Length).TrimStart('\')
            if (-not $seen.Add($rel)) { continue }
            $skip = $false
            foreach ($pat in $ignorePatterns) {
                if ($pat.IsMatch($rel)) { $skip = $true; break }
            }
            if ($skip) { $ignoredCount++; continue }
            $target = Get-LinkTargetOf $p
            if (-not $target) {
                # Windows 自带兼容链接在 PS 5.1 下读不出 Target，按其他链接忽略
                $otherLinkCount++
                continue
            }
            if (Test-UnderRoot $target $MigrationRoot) {
                [void]$migrationLinks.Add([pscustomobject]@{ Rel = $rel; Target = $target })
            }
            else {
                $otherLinkCount++
            }
        }
    }

    $candidates = @($migrationLinks | Where-Object { -not $csvRels.Contains($_.Rel) } | Sort-Object Rel)
    Write-Info "  迁移链接：$($migrationLinks.Count) 个（已记录 $($migrationLinks.Count - $candidates.Count) 个）"
    Write-Info "  其他链接：$otherLinkCount 个（系统兼容链接等，忽略）"
    if ($ignoredCount -gt 0) {
        Write-Info "  忽略残留：$ignoredCount 个（命中 ignoreRelPatterns，如安装器遗留的 .junction-*）"
    }

    Write-Step "未记录的迁移链接"
    if ($candidates.Count -eq 0) {
        Write-Ok "没有发现未记录的迁移链接"
    }
    else {
        Write-Warn "发现 $($candidates.Count) 个未记录，可用 -Record 写入 links.csv"
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $token = ConvertTo-TokenTarget $candidates[$i].Target $MigrationRoot
            Write-Host ("   {0,2}  {1}" -f ($i + 1), $candidates[$i].Rel) -ForegroundColor White
            Write-Host ("       -> {0}" -f $token) -ForegroundColor DarkGray
        }
    }

    # ---------------- 第 3 部分：按需写入清单
    if ($Record) {
        Write-Step "写入 links.csv"
        if ($candidates.Count -eq 0) {
            Write-Ok "没有需要新增的记录，links.csv 未改动"
        }
        else {
            $ans = $null
            try {
                $ans = Read-Host " 输入要记录的编号（如 1,3 或 1-3；a=全部；回车=不写入）"
            }
            catch { $ans = '' }
            if ($null -eq $ans -or -not $ans.Trim()) {
                Write-Skip "已取消，links.csv 未改动"
            }
            else {
                $picked = @()
                $bad = $false
                try { $picked = @(ConvertFrom-Selection $ans $candidates.Count) }
                catch {
                    Write-Err $_.Exception.Message
                    $bad = $true
                }
                if (-not $bad -and $picked.Count -gt 0) {
                    Write-Info "  将写入 $($picked.Count) 条："
                    foreach ($n in $picked) {
                        Say ("   {0}" -f $candidates[$n - 1].Rel) 'White'
                    }
                    if (Read-YesNo " 确认追加到 links.csv？" $false) {
                        $text = [System.IO.File]::ReadAllText($csvPath, (New-Object System.Text.UTF8Encoding($false)))
                        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
                        $today = Get-Date -Format 'yyyy-MM-dd'
                        $lines = @()
                        foreach ($n in $picked) {
                            $c = $candidates[$n - 1]
                            $token = ConvertTo-TokenTarget $c.Target $MigrationRoot
                            $lines += ('{0},{1},{2}' -f `
                                (Format-CsvField $c.Rel), `
                                (Format-CsvField $token), `
                                (Format-CsvField ("扫描记录 " + $today)))
                        }
                        $text += (($lines -join "`n") + "`n")
                        [System.IO.File]::WriteAllText($csvPath, $text, (New-Object System.Text.UTF8Encoding($false)))
                        Write-Ok "已追加 $($picked.Count) 条到 links.csv"
                        Write-Info "  建议重新跑一次 08-校验链接.ps1，确认全部通过"
                    }
                    else {
                        Write-Skip "已取消，links.csv 未改动"
                    }
                }
            }
        }
    }

    Write-Host ""
    Say "日志：$logFile" 'DarkGray'
    if ($failCount -gt 0) { $exitCode = 0 }
}
catch {
    Write-Err $_.Exception.Message
    $exitCode = 1
}
finally {
    Stop-KitLog
}
exit $exitCode
