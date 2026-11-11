#requires -Version 5.1
<#
    重建 junction 链接（阶段 3）
    ============================================================
    读取 links.csv，把「已迁移到 D 盘」的目录重新接回 C 盘用户目录。

    安全策略：
      - 目标（D 盘）不存在  -> 跳过并告警，绝不在 D 盘造空目录
      - C 盘该位置是空目录   -> 直接删掉，建链接
      - C 盘该位置有东西     -> 改名成 xxx.local-时间戳 保留，再建链接（不删任何用户数据）
      - C 盘该位置已是正确链接 -> 跳过

    用法：
      powershell -ExecutionPolicy Bypass -File 重建链接.ps1
      powershell -ExecutionPolicy Bypass -File 重建链接.ps1 -WhatIfOnly
#>
[CmdletBinding()]
param(
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
# 注意：不要改 [Console]::OutputEncoding，中文 Windows 控制台是 936，
# 强改成 UTF8 会让所有中文变成乱码。

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 迁移根目录：优先读本机私有配置，缺省按当前用户名推断
$MigrationRoot = $null
$configFile = Join-Path (Split-Path -Parent $scriptDir) 'local.config.ps1'
if (Test-Path -LiteralPath $configFile) { . $configFile }
if (-not $MigrationRoot) { $MigrationRoot = Join-Path 'D:\migration\C\Users' $env:USERNAME }

$csvCandidates = @(
    (Join-Path (Split-Path -Parent $scriptDir) 'links.csv'),
    (Join-Path $scriptDir 'links.csv'),
    'D:\Reinstall_Kit\links.csv'
)
$csvPath = $null
foreach ($c in $csvCandidates) { if (Test-Path -LiteralPath $c) { $csvPath = $c; break } }
if (-not $csvPath) { throw "找不到 links.csv，已尝试：`n$($csvCandidates -join "`n")" }

$logDir = Split-Path -Parent $scriptDir
$logPath = Join-Path $logDir ("logs\restore-links_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null
Start-Transcript -Path $logPath -Force | Out-Null

Write-Host ""
Write-Host "=== 重建链接 ===" -ForegroundColor Cyan
Write-Host "清单: $csvPath"
Write-Host "用户: $env:USERPROFILE"
Write-Host ""

# 用 Get-Content -Encoding UTF8 + ConvertFrom-Csv，避免 PS 5.1 下 Import-Csv 编码差异
$rows = (Get-Content -LiteralPath $csvPath -Encoding UTF8 -Raw) | ConvertFrom-Csv
$ok = 0; $skipped = 0; $failed = 0; $backedUp = 0

function Get-LinkTarget {
    param($Item)
    try {
        if ($Item.PSObject.Properties['Target'] -and $Item.Target) { return [string]$Item.Target }
    } catch {}
    try {
        if ($Item.PSObject.Properties['LinkTarget'] -and $Item.LinkTarget) { return [string]$Item.LinkTarget }
    } catch {}
    return $null
}

foreach ($row in $rows) {
    $rel    = $row.rel
    # 清单用 %MIGROOT% 与 %USERPROFILE% 占位，避免把本机用户名写进仓库
    $target = $row.target.Replace('%MIGROOT%', $MigrationRoot)
    $target = [Environment]::ExpandEnvironmentVariables($target)
    $link   = Join-Path $env:USERPROFILE $rel

    # --- 1. 目标必须存在 ---
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host ("  [跳过] {0} —— 目标不存在: {1}" -f $rel, $target) -ForegroundColor Yellow
        $skipped++
        continue
    }

    # --- 2. 已存在的处理 ---
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)

        if ($isLink) {
            $cur = Get-LinkTarget -Item $item
            if ($cur -and $cur.TrimEnd('\') -eq $target.TrimEnd('\')) {
                Write-Host ("  [已有] {0}" -f $rel) -ForegroundColor DarkGray
                $ok++
                continue
            }
            Write-Host ("  [重建] {0} 旧指向: {1}" -f $rel, $(if ($cur) { $cur } else { '<无法读取>' })) -ForegroundColor Yellow
            if (-not $WhatIfOnly) {
                if ($item.PSIsContainer) { [System.IO.Directory]::Delete($link, $false) }
                else { [System.IO.File]::Delete($link) }
            }
        }
        else {
            $childCount = 0
            if ($item.PSIsContainer) {
                $childCount = @(Get-ChildItem -LiteralPath $link -Force -ErrorAction SilentlyContinue).Count
            }
            else { $childCount = 1 }

            if ($childCount -eq 0) {
                Write-Host ("  [建链] {0}（原先是个空目录）" -f $rel) -ForegroundColor Green
                if (-not $WhatIfOnly) { Remove-Item -LiteralPath $link -Force -Recurse }
            }
            else {
                $stamp = Get-Date -Format 'HHmmss'
                $bak = "$link.local-$stamp"
                Write-Host ("  [改名] {0} 有 {1} 项内容，改名保留为 {2}" -f $rel, $childCount, (Split-Path $bak -Leaf)) -ForegroundColor Magenta
                if (-not $WhatIfOnly) { Rename-Item -LiteralPath $link -NewName (Split-Path $bak -Leaf) -Force }
                $backedUp++
            }
        }
    }

    # --- 3. 建链接 ---
    if ($WhatIfOnly) {
        Write-Host ("  [计划] {0} -> {1}" -f $rel, $target) -ForegroundColor Cyan
        continue
    }

    try {
        $parent = Split-Path $link -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        # 目标是文件时用符号链接（junction 只能指向目录）；建文件符号链接需要管理员权限
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null
        }
        else {
            New-Item -ItemType Junction -Path $link -Target $target -Force | Out-Null
        }
        Write-Host ("  [OK]   {0} -> {1}" -f $rel, $target) -ForegroundColor Green
        $ok++
    }
    catch {
        Write-Host ("  [失败] {0} : {1}" -f $rel, $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host ("=== 汇总：成功 {0} / 跳过 {1} / 改名保留 {2} / 失败 {3} ===" -f $ok, $skipped, $backedUp, $failed) `
    -ForegroundColor Cyan

if ($backedUp -gt 0) {
    Write-Host "提示：带 .local-时间戳 后缀的目录是原 C 盘内容，确认无用后可手工删除。" -ForegroundColor Yellow
}

# --- 4. 自检 ---
Write-Host ""
Write-Host "--- 自检 ----" -ForegroundColor Cyan
$bad = 0
foreach ($row in $rows) {
    $rel  = $row.rel
    $link = Join-Path $env:USERPROFILE $rel
    if (-not (Test-Path -LiteralPath $link)) {
        Write-Host ("  [缺失] " + $rel) -ForegroundColor Yellow
        $bad++
        continue
    }
    $item = Get-Item -LiteralPath $link -Force
    $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if (-not $isLink) {
        Write-Host ("  [非链接] " + $rel) -ForegroundColor Yellow
        $bad++
    }
}
if ($bad -eq 0) {
    Write-Host ("  全部 " + $rows.Count + " 条链接正常") -ForegroundColor Green
} else {
    Write-Host ("  " + $bad + " 条异常，共 " + $rows.Count + " 条") -ForegroundColor Yellow
}

Stop-Transcript | Out-Null
Write-Host "日志: $logPath" -ForegroundColor DarkGray
if ($failed -gt 0) { exit 1 } else { exit 0 }
