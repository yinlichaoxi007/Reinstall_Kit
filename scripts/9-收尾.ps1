#requires -Version 5.1
<#
    重装后收尾检查
    ============================================================
    跑完 bootstrap（重建链接 + 装软件）之后用这个脚本核对一遍：
        · 37 条链接是不是都真的接上了
        · C 盘空间、D 盘盘符对不对
        · 激活状态
        · 备份数据要不要拷回来（默认只看不拷）
        · Dell 驱动 / 内存瘦身 还差哪一步

    用法：
        开始.cmd  →  7
        或： powershell -ExecutionPolicy Bypass -File 9-收尾.ps1
            powershell -ExecutionPolicy Bypass -File 9-收尾.ps1 -RestoreData
#>
[CmdletBinding()]
param(
    [switch]$RestoreData,
    [string]$BackupDir = ''
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'post-setup' | Out-Null
Write-Head "重装后收尾检查"

$issues = New-Object System.Collections.ArrayList

# ================================================================= 1 系统
Write-Step "1. 系统"

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Write-Info ("{0}  build {1}  {2}" -f $os.Caption, $build, $os.OSArchitecture)
if ($build -ge 19041 -and $build -lt 22000) { Write-Ok "Win10，符合预期" }
elseif ($build -ge 22000) { Write-Warn "还是 Win11 —— 重装没成功？" ; $null = $issues.Add('系统仍是 Win11') }

$c = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
if ($c) {
    Write-Info ("C: 总 {0} / 可用 {1}" -f (Format-Human $c.Size), (Format-Human $c.SizeRemaining))
    if ($c.SizeRemaining -lt 20GB) { Write-Warn "C 盘可用不足 20GB"; $null = $issues.Add('C 盘空间偏小') }
}

$d = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
if (-not $d) {
    Write-Err "D 盘不存在。检查 SATA 线是否插回、盘符是否被改成别的字母。"
    $null = $issues.Add('D 盘缺失')
} else {
    Write-Info ("D: 卷标 {0}  可用 {1}" -f $d.FileSystemLabel, (Format-Human $d.SizeRemaining))
    if ($d.FileSystemLabel -ne 'DATA') { Write-Warn "卷标不是 DATA（bootstrap 靠卷标找盘，之后要改回来）" }
    if (-not (Test-Path -LiteralPath 'D:\migration')) {
        Write-Warn "D:\migration 不在 —— 链接的目标都没了"
        $null = $issues.Add('D:\migration 缺失')
    } else { Write-Ok "D:\migration 在" }
}

# ================================================================= 2 链接
Write-Step "2. 链接（37 条）"

$csvPath = Join-Path $script:KitRoot 'links.csv'
if (Test-Path -LiteralPath $csvPath) {
    $rows = (Get-Content -LiteralPath $csvPath -Encoding UTF8 -Raw) | ConvertFrom-Csv
    $ok = 0; $bad = @()
    foreach ($r in $rows) {
        $link = Join-Path $env:USERPROFILE $r.rel
        if (-not (Test-Path -LiteralPath $link)) { $bad += ($r.rel + ' [缺失]'); continue }
        $it = Get-Item -LiteralPath $link -Force
        $isLink = [bool]($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isLink) { $ok++ } else { $bad += ($r.rel + ' [不是链接]') }
    }
    if ($bad.Count -eq 0) {
        Write-Ok ("{0}/{0} 条全部就绪" -f $ok)
    } else {
        Write-Warn ("{0}/{1} 条正常，{2} 条有问题：" -f $ok, @($rows).Count, $bad.Count)
        foreach ($b in $bad) { Write-Info ("    " + $b) }
        $null = $issues.Add("$($bad.Count) 条链接异常")
        Write-Info "修复：菜单 6（重跑 2-重建链接.ps1，已存在的会自动跳过）"
    }
} else {
    Write-Warn "links.csv 不存在"
}

# ================================================================= 3 激活
Write-Step "3. 激活"

$sl = & cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /dli 2>&1 | Out-String
if ($sl -match '已授权|Licensed') { Write-Ok "已授权" }
elseif ($sl -match '通知|Notification') { Write-Warn "未激活（通知状态）"; $null = $issues.Add('系统未激活') }
else { Write-Info "状态读不出来，手动看：slmgr /dli" }

# ================================================================= 4 软件
Write-Step "4. 关键软件"

$probes = @(
    @{ Name = 'winget'; Path = 'winget.exe'; Cmd = $true },
    @{ Name = 'Dell Command Update'; Path = 'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe'; Cmd = $false },
    @{ Name = 'WorkBuddy'; Path = "$env:LOCALAPPDATA\Programs\WorkBuddy\WorkBuddy.exe"; Cmd = $false },
    @{ Name = 'Git'; Path = 'git.exe'; Cmd = $true },
    @{ Name = '7-Zip'; Path = 'C:\Program Files\7-Zip\7z.exe'; Cmd = $false }
)
foreach ($p in $probes) {
    $found = $false
    if ($p.Cmd) { $found = [bool](Get-Command $p.Path -ErrorAction SilentlyContinue) }
    else { $found = Test-Path -LiteralPath $p.Path }
    if ($found) { Write-Ok $p.Name } else { Write-Warn ("{0} —— 没找到" -f $p.Name) }
}

$resultLogs = @(Get-ChildItem -LiteralPath (Join-Path $script:KitRoot 'logs') -Filter '安装结果_*.md' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
if ($resultLogs.Count -gt 0) {
    Write-Info ("最近一次安装记录: " + $resultLogs[0].Name)
    Write-Info ("  " + $resultLogs[0].FullName)
} else {
    Write-Warn "还没有安装记录 —— 可能 3-装软件 没跑过"
    $null = $issues.Add('软件安装未执行')
}

# ================================================================= 5 数据恢复
Write-Step "5. 备份数据恢复"

$backupRoot = Join-Path $script:KitRoot 'backup'
if (-not $BackupDir) {
    $latest = Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { $BackupDir = $latest.FullName }
}
if (-not $BackupDir -or -not (Test-Path -LiteralPath $BackupDir)) {
    Write-Warn "找不到备份目录，跳过。"
} else {
    Write-Info ("备份目录: " + $BackupDir)
    $dirs = @('Documents', 'Desktop', 'Downloads', 'Pictures', 'AppData\Roaming\Mozilla')
    foreach ($rel in $dirs) {
        $src = Join-Path $BackupDir $rel
        $dst = Join-Path $env:USERPROFILE $rel
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $srcCount = @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue).Count
        $dstCount = 0
        if (Test-Path -LiteralPath $dst) { $dstCount = @(Get-ChildItem -LiteralPath $dst -Recurse -File -ErrorAction SilentlyContinue).Count }
        Write-Info ("  {0,-24} 备份 {1,5} 个文件 / 当前 {2,5} 个" -f $rel, $srcCount, $dstCount)
    }

    if ($RestoreData) {
        Write-Host ""
        Write-Warn "恢复会用备份里的同名文件覆盖 C 盘的现有文件（不会删除多出来的文件）"
        if (-not (Read-YesNo "确认开始恢复" $false)) {
            Write-Info "已跳过恢复。"
        } else {
            foreach ($rel in $dirs) {
                $src = Join-Path $BackupDir $rel
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $dst = Join-Path $env:USERPROFILE $rel
                Write-Info ("  robocopy {0} ..." -f $rel)
                $null = & robocopy $src $dst /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
                if ($LASTEXITCODE -lt 8) { Write-Ok ("  " + $rel) } else { Write-Warn ("  {0} 退出码 {1}" -f $rel, $LASTEXITCODE) }
            }
        }
    } else {
        Write-Info "只查看不拷贝。要真的拷回来：加 -RestoreData"
    }
}

# ================================================================= 6 下一步
Write-Step "6. 还差什么"

$next = @()
if ($issues.Count -eq 0) { Write-Ok "没有发现明显问题" }
else {
    foreach ($i in $issues) { Write-Warn $i }
}

Write-Host ""
Write-Host "  建议顺序：" -ForegroundColor Cyan
Write-Host "    · 菜单 10/11  内存瘦身与 explorer 守护（重装后重跑一次）"
Write-Host "    · 装 Dell 驱动：Dell Command Update 一键补齐"
Write-Host "    · 设密码：net user $env:USERNAME *  （现在是空密码）"
Write-Host "    · 用一个月没问题，再考虑菜单 8 回收那 18 GB"
Write-Host ""

Stop-KitLog
if ($issues.Count -gt 0) { exit 0 } else { exit 0 }
