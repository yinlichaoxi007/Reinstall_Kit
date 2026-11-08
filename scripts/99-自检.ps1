#requires -Version 5.1
<#
    工程包自检
    ============================================================
    在动真格之前，先把所有脚本"过一遍机器"：
        1. 语法解析（PowerShell Parser，能抓出 ???、括号不配对、参数写错）
        2. 已知反模式扫描（覆盖 $args、Write-Host 后接 -f 等）
        3. Python 脚本编译
        4. XML / JSON / CSV 可解析
        5. 依赖文件是否齐
        6. 安全干跑：0-体检 与 10-回收恢复分区 -Apply -DryRun（都有闸门，不会改东西）

    用法：
        开始.cmd  →  0
        或： powershell -ExecutionPolicy Bypass -File 99-自检.ps1
            powershell -ExecutionPolicy Bypass -File 99-自检.ps1 -SkipRun

    退出码：0 = 全通过；1 = 有失败项
#>
[CmdletBinding()]
param(
    [switch]$SkipRun,
    [int]$RunTimeoutSec = 240
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'selftest' | Out-Null
Write-Head "工程包自检"

$results = New-Object System.Collections.ArrayList
function Add-Result {
    param([string]$Level, [string]$Item, [string]$Detail)
    $null = $results.Add([pscustomobject]@{ Level = $Level; Item = $Item; Detail = $Detail })
    switch ($Level) {
        'PASS' { Write-Host ("  [通过] {0,-34} {1}" -f $Item, $Detail) -ForegroundColor Green }
        'FAIL' { Write-Host ("  [失败] {0,-34} {1}" -f $Item, $Detail) -ForegroundColor Red }
        default { Write-Host ("  [提示] {0,-34} {1}" -f $Item, $Detail) -ForegroundColor Gray }
    }
}

# ================================================================= 1 语法
Write-Step "1. PowerShell 语法解析"

$psFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name)
foreach ($f in $psFiles) {
    $tokens = $null
    $errs = $null
    try {
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    } catch {
        Add-Result 'FAIL' $f.Name ('解析器异常: ' + $_.Exception.Message)
        continue
    }
    if ($errs -and $errs.Count -gt 0) {
        $first = $errs[0]
        Add-Result 'FAIL' $f.Name ("{0} 处语法错误，首个在第 {1} 行: {2}" -f $errs.Count, $first.Extent.StartLineNumber, $first.Message)
    } else {
        Add-Result 'PASS' $f.Name ("{0} 行" -f (Get-Content -LiteralPath $f.FullName).Count)
    }
}

# ================================================================= 2 反模式
Write-Step "2. 已知反模式扫描"

$patterns = @(
    @{ Name = '$args 赋值'; Regex = '^\s*\$args\s*='; Why = '$args 是自动变量，赋值会报只读错误' },
    @{ Name = 'Write-* 后接 -f'; Regex = 'Write-(Host|Info|Warn|Ok|Err|Skip|Danger|Step|Head)\s+"[^"]*"\s+-f\s'; Why = '格式化必须用括号包起来：Write-X ("..." -f a,b)' },
    @{ Name = '强改控制台编码'; Regex = '\[Console\]::OutputEncoding\s*='; Why = '强制 UTF8 会让中文控制台乱码' },
    @{ Name = 'PS7 空合并 ??'; Regex = '\?\?'; Why = 'PowerShell 5.1 不支持 ??' },
    @{ Name = 'PS7 三元 ?:'; Regex = '\?\s+[^:\r\n]+\s+:\s'; Why = 'PowerShell 5.1 不支持三元运算符' }
)

$hit = 0
foreach ($f in $psFiles) {
    if ($f.Name -eq '99-自检.ps1') { continue }   # 本文件里就有这些模式的定义，跳过
    $lines = Get-Content -LiteralPath $f.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($p in $patterns) {
            if ($lines[$i] -match $p.Regex) {
                # 注释行跳过
                if ($lines[$i].TrimStart().StartsWith('#')) { continue }
                Add-Result 'FAIL' ($f.Name + ":" + ($i + 1)) ($p.Name + ' —— ' + $p.Why)
                $hit++
            }
        }
    }
}
if ($hit -eq 0) { Add-Result 'PASS' '反模式' '5 类全部未命中' }

# ================================================================= 3 Python
Write-Step "3. Python 脚本编译"

$pyCandidates = @(
    (Join-Path $env:USERPROFILE '.workbuddy\binaries\python\versions\3.13.12\python.exe'),
    'python',
    'py'
)
$pyExe = $null
foreach ($c in $pyCandidates) {
    if (Test-Path -LiteralPath $c) { $pyExe = $c; break }
    if (Get-Command $c -ErrorAction SilentlyContinue) { $pyExe = $c; break }
}

$pyFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.py' -File)
if ($pyFiles.Count -eq 0) {
    Add-Result 'INFO' 'Python' '没有 .py 脚本'
} elseif (-not $pyExe) {
    Add-Result 'INFO' 'Python' '本机没有 python，跳过编译检查'
} else {
    foreach ($f in $pyFiles) {
        $out = & $pyExe -m py_compile $f.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { Add-Result 'PASS' $f.Name '编译通过' }
        else { Add-Result 'FAIL' $f.Name ($out.Trim() -replace "`r?`n", ' | ') }
    }
}

# ================================================================= 4 数据文件
Write-Step "4. XML / JSON / CSV"

$xmls = @(Get-ChildItem -LiteralPath (Split-Path -Parent $PSScriptRoot) -Filter 'autounattend*.xml' -File)
foreach ($x in $xmls) {
    if (Test-XmlFile -Path $x.FullName) { Add-Result 'PASS' $x.Name 'XML 合法' }
    else { Add-Result 'FAIL' $x.Name 'XML 解析失败' }
}

foreach ($n in @('packages-core.json', 'packages-all.json')) {
    $p = Join-Path (Split-Path -Parent $PSScriptRoot) $n
    if (-not (Test-Path -LiteralPath $p)) { Add-Result 'FAIL' $n '不存在'; continue }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $cnt = 0
        if ($j.Sources -and $j.Sources[0].Packages) { $cnt = @($j.Sources[0].Packages).Count }
        Add-Result 'PASS' $n ("{0} 个包" -f $cnt)
    } catch { Add-Result 'FAIL' $n 'JSON 解析失败' }
}

$csv = Join-Path (Split-Path -Parent $PSScriptRoot) 'links.csv'
if (Test-Path -LiteralPath $csv) {
    try {
        $rows = (Get-Content -LiteralPath $csv -Encoding UTF8 -Raw) | ConvertFrom-Csv
        $cols = @($rows[0].PSObject.Properties.Name)
        if ($cols -contains 'rel' -and $cols -contains 'target') {
            Add-Result 'PASS' 'links.csv' ("{0} 条，列: {1}" -f @($rows).Count, ($cols -join ','))
        } else {
            Add-Result 'FAIL' 'links.csv' ('列名不对: ' + ($cols -join ','))
        }
    } catch { Add-Result 'FAIL' 'links.csv' 'CSV 解析失败' }
} else { Add-Result 'FAIL' 'links.csv' '不存在' }

# ================================================================= 5 依赖
Write-Step "5. 依赖文件"

$need = @(
    @{ P = 'D:\Reinstall_Kit\DellFactoryImage\MANIFEST.json'; N = '出厂镜像清单' },
    @{ P = 'D:\Reinstall_Kit\DellFactoryImage\P5_Image\Image\install.swm'; N = '出厂镜像 install.swm' },
    @{ P = 'D:\软件包\系统\Win10_IoT_Enterprise_LTSC_2021_64-Bit_2608.iso'; N = '安装 ISO' }
)
foreach ($n in $need) {
    if (Test-Path -LiteralPath $n.P) { Add-Result 'PASS' $n.N '在' }
    else { Add-Result 'FAIL' $n.N '缺失' }
}

$appinst = Join-Path (Split-Path -Parent $PSScriptRoot) 'pkgs\appinstaller'
if (Test-Path -LiteralPath $appinst) { Add-Result 'PASS' 'winget 离线包' '目录在' }
else { Add-Result 'INFO' 'winget 离线包' '还没准备（菜单 3）' }

# ================================================================= 6 干跑
Write-Step "6. 安全干跑"

if ($SkipRun) {
    Add-Result 'INFO' '干跑' '已按 -SkipRun 跳过'
} else {
    $runs = @(
        @{ Name = '0-体检.ps1'; Args = @(); AllowExit = @(0, 1); MustContain = '重装工程包体检' },
        @{ Name = '10-回收恢复分区.ps1'; Args = @('-Apply', '-DryRun'); AllowExit = @(0, 1); MustContain = '闸门' },
        @{ Name = '11-出厂镜像还原.ps1'; Args = @(); AllowExit = @(0, 1); MustContain = '已生成' },
        @{ Name = '12-准备离线包.ps1'; Args = @('-DryRun'); AllowExit = @(0, 1); MustContain = '准备 winget 离线包' }
        @{ Name = '16-校验链接.ps1'; Args = @('-SelfTest'); AllowExit = @(0); MustContain = '检测逻辑有效' }
    )
    foreach ($r in $runs) {
        $script = Join-Path $PSScriptRoot $r.Name
        if (-not (Test-Path -LiteralPath $script)) { Add-Result 'FAIL' $r.Name '文件不存在'; continue }

        Write-Info ("  正在跑 {0} {1}（超时 {2}s）..." -f $r.Name, ($r.Args -join ' '), $RunTimeoutSec)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $script, ($r.Args -join ' '))
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(936)
        $psi.StandardErrorEncoding = [System.Text.Encoding]::GetEncoding(936)

        try {
            $p = [System.Diagnostics.Process]::Start($psi)
            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $p.StandardError.ReadToEnd()
            $finished = $p.WaitForExit($RunTimeoutSec * 1000)
            if (-not $finished) { try { $p.Kill() } catch { } }
            $code = if ($finished) { $p.ExitCode } else { -999 }
        } catch {
            Add-Result 'FAIL' $r.Name ('启动失败: ' + $_.Exception.Message)
            continue
        }

        $all = $stdout + "`n" + $stderr
        $badWords = @('ParserError', '无法识别', 'CommandNotFoundException', '不能将', '不是内部或外部命令', 'Unhandled exception')
        $foundBad = @()
        foreach ($w in $badWords) { if ($all -like ('*' + $w + '*')) { $foundBad += $w } }

        if (-not $finished) {
            Add-Result 'FAIL' $r.Name ("超时 {0}s 未结束（可能卡在 Read-Host）" -f $RunTimeoutSec)
        } elseif ($foundBad.Count -gt 0) {
            Add-Result 'FAIL' $r.Name ('输出里有异常关键字: ' + ($foundBad -join ','))
        } elseif ($r.AllowExit -notcontains $code) {
            Add-Result 'FAIL' $r.Name ("退出码 {0}（预期 {1}）" -f $code, ($r.AllowExit -join '/'))
        } elseif ($all -notlike ('*' + $r.MustContain + '*')) {
            Add-Result 'FAIL' $r.Name ('没跑到关键环节，输出里没有 "' + $r.MustContain + '"')
        } else {
            Add-Result 'PASS' $r.Name ("退出码 {0}，输出 {1} 行" -f $code, ($all -split "`n").Count)
        }
    }
}

# ================================================================= 报告
Write-Head "结论"

$fails = @($results | Where-Object { $_.Level -eq 'FAIL' })
$passes = @($results | Where-Object { $_.Level -eq 'PASS' })

Write-Info ("通过 {0} / 失败 {1} / 提示 {2}" -f $passes.Count, $fails.Count, @($results | Where-Object { $_.Level -eq 'INFO' }).Count)

$reportPath = Join-Path $script:KitRoot ('logs\自检报告_{0}.md' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$md = @()
$md += '# 工程包自检报告'
$md += ''
$md += ('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$md += ''
$md += ('结果：**通过 {0} / 失败 {1}**' -f $passes.Count, $fails.Count)
$md += ''
$md += '| 结果 | 项目 | 说明 |'
$md += '|---|---|---|'
foreach ($x in $results) {
    $tag = '提示'
    if ($x.Level -eq 'PASS') { $tag = '通过' }
    if ($x.Level -eq 'FAIL') { $tag = '失败' }
    $md += ('| {0} | {1} | {2} |' -f $tag, $x.Item, ($x.Detail -replace '\|', '/'))
}
$md += ''
$md += '## 说明'
$md += ''
$md += '- 干跑项只验证「能跑起来、不卡住、走到预期环节」，不会改任何数据。'
$md += '- 7-做U盘 / 8-重启 需要真实 U 盘与重启，无法自动化，靠人工走一遍。'
[System.IO.File]::WriteAllText($reportPath, (($md -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
Write-Info ("报告: " + $reportPath)

Write-Host ""
if ($fails.Count -gt 0) {
    Write-Err "有失败项，先修再往下走。"
    foreach ($f in $fails) { Write-Host ("    · {0} —— {1}" -f $f.Item, $f.Detail) -ForegroundColor Red }
    Stop-KitLog
    exit 1
}

Write-Ok "全部通过。"
Stop-KitLog
exit 0
