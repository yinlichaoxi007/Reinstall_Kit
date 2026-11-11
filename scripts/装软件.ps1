#requires -Version 5.1
<#
    批量安装常用软件（阶段 3）
    ============================================================
    优先 winget（用本机实测导出的精确 PackageId），
    winget 不可用时自动装 Chocolatey 兜底。

    用法：
      powershell -ExecutionPolicy Bypass -File 装软件.ps1
      powershell -ExecutionPolicy Bypass -File 装软件.ps1 -Manifest packages-all.json
      powershell -ExecutionPolicy Bypass -File 装软件.ps1 -SkipHeavy      # 跳过 VS/JetBrains/Unity/Docker

    结果输出：<Kit>\logs\安装结果_<时间>.md
#>
[CmdletBinding()]
param(
    [string]$Manifest = 'packages-core.json',
    [string]$InstallRoot = '',
    [switch]$SkipHeavy,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
# 不改 [Console]::OutputEncoding，保持中文 Windows 默认的 936

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitDir    = Split-Path -Parent $scriptDir
if (-not (Test-Path (Join-Path $KitDir 'links.csv'))) { $KitDir = 'D:\Reinstall_Kit' }

# 安装根与迁移根都来自 kit.config.json；没配时安装根退回「工程包所在盘\Programs」
$kitCfg = $null
$kitCfgFile = Join-Path $KitDir 'kit.config.json'
if (Test-Path -LiteralPath $kitCfgFile) {
    try { $kitCfg = Get-Content -LiteralPath $kitCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$MigrationRoot = if ($kitCfg) { [string]$kitCfg.migrationRoot } else { '' }
if (-not $InstallRoot) {
    if ($kitCfg -and $kitCfg.installRoot) { $InstallRoot = [string]$kitCfg.installRoot }
    else { $InstallRoot = (Split-Path -Qualifier $KitDir) + '\Programs' }
}

$LogDir = Join-Path $KitDir 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogTxt = Join-Path $LogDir "install_$Stamp.log"
$LogMd  = Join-Path $LogDir "安装结果_$Stamp.md"

function Say($msg, $color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
    Add-Content -LiteralPath $LogTxt -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8
}

# winget 单包可能装几分钟且 --silent 模式没有输出；
# 用 Start-Process + 轮询：单行显示已等待秒数 + winget 日志的最新一行
function Invoke-WingetLive {
    param([string[]]$WingetArgs, [string]$Prefix, [string]$FilePath = 'winget.exe')
    $tmpOut = Join-Path $env:TEMP ("live_out_{0}.txt" -f $PID)
    $tmpErr = Join-Path $env:TEMP ("live_err_{0}.txt" -f $PID)
    $quoted = ($WingetArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $p = Start-Process -FilePath $FilePath -ArgumentList $quoted -NoNewWindow -PassThru `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    $t0 = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(500)) {
        $tail = ''
        try {
            $line = Get-Content -LiteralPath $tmpOut -Tail 1 -ErrorAction SilentlyContinue
            if ($line) { $tail = ([string]$line).Trim() }
        } catch { }
        if ($tail.Length -gt 44) { $tail = $tail.Substring(0, 44) }
        $text = "  {0}  已等待 {1} 秒  {2}" -f $Prefix, [int]$t0.Elapsed.TotalSeconds, $tail
        if ($text.Length -gt 100) { $text = $text.Substring(0, 100) }
        Write-Host ("`r" + $text + (" " * [Math]::Max(0, 104 - $text.Length))) -NoNewline -ForegroundColor Gray
    }
    Write-Host ""
    $out = ''
    try {
        $out = (Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        $errText = (Get-Content -LiteralPath $tmpErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($errText) { $out = $out + "`r`n" + $errText }
    } catch { }
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = [string]$out }
}

# 体积大 / 耗时长的包
$HeavyIds = @(
    'Microsoft.VisualStudio.Professional', 'Microsoft.VisualStudio.Community',
    'JetBrains.GoLand', 'JetBrains.IntelliJIDEA', 'JetBrains.Rider', 'JetBrains.PyCharm',
    'JetBrains.CLion', 'JetBrains.WebStorm',
    'Unity.UnityHub', 'Unity.Unity.2020', 'Unity.TuanjieHub',
    'Docker.DockerDesktop', 'BlenderFoundation.Blender',
    'Microsoft.SQLServer.2019.Developer', 'Autodesk.AutoCAD'
)

# ---------------------------------------------------------------- winget
function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say ("winget 已可用：{0}" -f (winget --version 2>$null)) 'Green'
        return $true
    }

    Say "winget 不存在（Win10 22H2 不自带），尝试离线安装 App Installer ..." 'Yellow'
    $cands = @((Join-Path $KitDir 'pkgs\appinstaller'), (Join-Path $scriptDir 'pkgs\appinstaller'))
    $dir = $null
    foreach ($c in $cands) { if (Test-Path $c) { $dir = $c; break } }

    if ($dir) {
        # 依赖顺序不能乱：VCLibs -> UI.Xaml -> App Installer 本体
        # 注意 .appx 也要装，只过滤 *.msix* 会漏掉前两个依赖
        foreach ($pat in @('*VCLibs*', '*UI.Xaml*', '*WindowsAppRuntime*', '*DesktopAppInstaller*')) {
            Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pat -and $_.Extension -in '.appx', '.msix', '.msixbundle' } |
                ForEach-Object {
                    try {
                        Say ("  安装 {0}" -f $_.Name)
                        Add-AppxPackage -Path $_.FullName -ErrorAction Stop
                    } catch {
                        Say ("  跳过 {0}: {1}" -f $_.Name, $_.Exception.Message) 'DarkYellow'
                    }
                }
        }
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say "winget 安装成功" 'Green'
        return $true
    }

    Say "离线包不存在，尝试打开应用商店（需要联网）..." 'Yellow'
    try {
        Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1'
        Say "已打开『应用安装程序』页面，手动点『获取』装好后重跑本脚本。" 'Yellow'
    } catch {
        Say "无法打开商店。" 'Red'
    }
    return $false
}

# ---------------------------------------------------------------- choco 兜底
function Ensure-Choco {
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    Say "安装 Chocolatey ..." 'Yellow'
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        return [bool](Get-Command choco -ErrorAction SilentlyContinue)
    } catch {
        Say ("Chocolatey 安装失败：{0}" -f $_.Exception.Message) 'Red'
        return $false
    }
}

$ChocoMap = @{
    'Git.Git'                       = 'git'
    'TortoiseGit.TortoiseGit'       = 'tortoisegit'
    'Microsoft.VisualStudioCode'    = 'vscode'
    'Python.Python.3.12'            = 'python312'
    'GoLang.Go'                     = 'golang'
    'voidtools.Everything'          = 'everything'
    'Notepad++.Notepad++'           = 'notepadplusplus'
    'Sogou.SogouInput'              = 'sogouinput'
    'Tencent.WeChat.Universal'      = 'wechat'
    'Joplin.Joplin'                 = 'joplin'
    'MarkText.MarkText'             = 'marktext'
    'WiresharkFoundation.Wireshark' = 'wireshark'
    'Graphviz.Graphviz'             = 'graphviz'
    'VideoLAN.VLC'                  = 'vlc'
    'LocalSend.LocalSend'           = 'localsend'
    'Baidu.BaiduNetdisk'            = 'baidunetdisk'
    'Microsoft.OneDrive'            = 'onedrive'
    'EclipseFoundation.Mosquitto'   = 'mosquitto'
    'Oracle.JavaRuntimeEnvironment' = 'javaruntime'
    'NSIS.NSIS'                     = 'nsis'
    'JRSoftware.InnoSetup.7'        = 'innosetup'
    'TheDocumentFoundation.LibreOffice' = 'libreoffice-fresh'
}

# ---------------------------------------------------------------- 主流程
Say ""
Say "=== 批量安装 ===" 'Cyan'

$manifestPath = Join-Path $KitDir $Manifest
if (-not (Test-Path $manifestPath)) { $manifestPath = Join-Path $scriptDir $Manifest }
if (-not (Test-Path $manifestPath)) { throw "找不到清单文件：$Manifest" }
Say ("清单: {0}" -f $manifestPath)

$json = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ids = @()
foreach ($src in $json.Sources) {
    foreach ($p in $src.Packages) { if ($p.PackageIdentifier) { $ids += $p.PackageIdentifier } }
}
$ids = @($ids | Select-Object -Unique)
Say ("共 {0} 个包" -f $ids.Count)

if ($DryRun) {
    Say ""
    Say "=== 演练模式：只列清单，不安装 ===" 'Cyan'
    Say ("系统级软件会尝试装到: {0}\<包ID>" -f $InstallRoot)
    Say  "用户级软件走 junction，落在迁移根目录下（kit.config.json 的 migrationRoot）"
    Say ""
    $i = 0
    foreach ($id in $ids) {
        $i++
        $tag = if ($HeavyIds -contains $id) { ' [大体积]' } else { '' }
        Say ("  [{0}/{1}] {2}{3}" -f $i, $ids.Count, $id, $tag)
    }
    Say ""
    Say ("演练结束，共 {0} 个包，其中大体积 {1} 个。" -f $ids.Count, @($ids | Where-Object { $HeavyIds -contains $_ }).Count) 'Cyan'
    exit 0
}

$haveWinget = Ensure-Winget
$haveChoco  = $false
if (-not $haveWinget) {
    Say "winget 不可用，切换到 Chocolatey 方案" 'Yellow'
    $haveChoco = Ensure-Choco
    if (-not $haveChoco) { throw "winget 与 Chocolatey 都不可用，请检查网络后重试" }
}

# ---------------------------------------------------------------- 安装位置
if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        try { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null } catch { }
    }
}
Say ""
Say "=== 安装位置策略 ===" 'Cyan'
Say ("  系统级软件根目录: {0}" -f $InstallRoot)
Say  "  用户级软件（VSCode / WorkBuddy / Qoder / Trae 等）：由 junction 指到"
Say ("      {0}\AppData\Local\Programs（路径见 kit.config.json 的 migrationRoot）" -f `
        $(if ($MigrationRoot) { $MigrationRoot } else { '<迁移根>' }))
Say  "  少数安装器不认 --location（如 msix / 商店包），会自动回退默认位置，报告里标出来"
Say  "  提示：机械硬盘上跑 IDE / 编译器这类天天用又吃 IO 的程序，留 C 盘更划算"
Say ""

if ($haveWinget) {
    Say "刷新 winget 源索引 ..."
    winget source update 2>&1 | Out-Null
}

# C 盘 Program Files 基线，用于事后点名"哪些还是装到了 C"
$cDirsBefore = @()
foreach ($pf in @('C:\Program Files', 'C:\Program Files (x86)')) {
    if (Test-Path -LiteralPath $pf) {
        foreach ($d in (Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue)) {
            $cDirsBefore += ($pf + '|' + $d.Name)
        }
    }
}

$results = @()
$i = 0
foreach ($id in $ids) {
    $i++
    $prefix = "[{0}/{1}] {2}" -f $i, $ids.Count, $id

    if ($SkipHeavy -and ($HeavyIds -contains $id)) {
        Say "$prefix  -> 跳过（-SkipHeavy）" 'DarkGray'
        $results += [pscustomobject]@{ Id = $id; Result = '跳过'; Note = '大体积包，需单独安装'; Where = '' }
        continue
    }

    Say "$prefix  -> 安装中 ..."

    if ($haveWinget) {
        $safe = ($id -replace '[\\/:*?"<>|]', '_')
        $loc = Join-Path $InstallRoot $safe
        if (-not $DryRun -and -not (Test-Path -LiteralPath $loc)) {
            try { New-Item -ItemType Directory -Path $loc -Force | Out-Null } catch { }
        }

        $base = @('install', '--id', $id, '--exact', '--silent',
                  '--accept-package-agreements', '--accept-source-agreements',
                  '--disable-interactivity', '--source', 'winget')
        if ($Force) { $base += '--force' }

        $wargs = $base + @('--location', $loc)
        $r     = Invoke-WingetLive -WingetArgs $wargs -Prefix $prefix
        $out   = $r.Output
        $code  = $r.ExitCode
        $note  = ''

        # 安装器不认 --location 时回退一次（msix / 商店包 / 部分 EXE 安装器）
        if ($code -ne 0 -and ($out -match 'location|--location|位置参数|0x8A150')) {
            Say "$prefix  -> 这个安装器不接受自定义路径，回退默认位置重试" 'Yellow'
            $r2   = Invoke-WingetLive -WingetArgs $base -Prefix $prefix
            $code = $r2.ExitCode
            $out  = $out + "`r`n--- 回退（不带 --location）---`r`n" + $r2.Output
            $note = '不支持 --location，装到默认位置'
        }

        Add-Content -LiteralPath $LogTxt -Value $out -Encoding UTF8

        if ($code -eq 0) {
            $where = '?'
            if (-not $DryRun) {
                $cnt = 0
                try { $cnt = @(Get-ChildItem -LiteralPath $loc -Force -ErrorAction SilentlyContinue).Count } catch { }
                if ($cnt -gt 0) { $where = 'D' }
            }
            Say "$prefix  -> 成功（位置 $where）" 'Green'
            $results += [pscustomobject]@{ Id = $id; Result = '成功'; Note = $note; Where = $where }
        }
        elseif ($code -eq -1978335189 -or $code -eq -1978335212) {
            Say "$prefix  -> 已安装或无需更新" 'DarkGray'
            $results += [pscustomobject]@{ Id = $id; Result = '已安装'; Note = "exit $code"; Where = '' }
        }
        elseif ($out -match '已安装|already installed|找到已安装') {
            Say "$prefix  -> 已安装" 'DarkGray'
            $results += [pscustomobject]@{ Id = $id; Result = '已安装'; Note = ''; Where = '' }
        }
        else {
            Say "$prefix  -> 失败（exit $code）" 'Red'
            $results += [pscustomobject]@{ Id = $id; Result = '失败'; Note = "winget exit $code"; Where = '' }
        }
    }
    elseif ($haveChoco -and $ChocoMap.ContainsKey($id)) {
        $r = Invoke-WingetLive -FilePath 'choco.exe' `
                -WingetArgs @('install', $ChocoMap[$id], '-y', '--no-progress') -Prefix $prefix
        $out = $r.Output
        Add-Content -LiteralPath $LogTxt -Value $out -Encoding UTF8
        if ($r.ExitCode -eq 0) {
            Say "$prefix  -> 成功(choco)" 'Green'
            $results += [pscustomobject]@{ Id = $id; Result = '成功'; Note = 'choco:' + $ChocoMap[$id]; Where = 'C' }
        } else {
            Say "$prefix  -> 失败(choco)" 'Red'
            $results += [pscustomobject]@{ Id = $id; Result = '失败'; Note = 'choco exit ' + $r.ExitCode; Where = '' }
        }
    }
    else {
        Say "$prefix  -> 无可用渠道" 'Yellow'
        $results += [pscustomobject]@{ Id = $id; Result = '未处理'; Note = 'choco 无对应包名'; Where = '' }
    }
}

# ---------------------------------------------------------------- 本地安装包
# pkgs\local\ 下的 *.exe / *.msi 会被静默安装，用于 winget 源里没有的软件。
# 注意：这里**无法指定安装目录**——各家安装器的参数写法不同（MSI 属性名 / NSIS 的 /D= /
# Inno 的 /DIR= / InstallShield 的 /v"INSTALLDIR="），盲试只会装到默认位置或弹窗卡住。
# 想装到 D 盘的软件请装完系统手动双击安装。每个包最多等 3 分钟，超时就跳过，不会卡死。
$localDir = Join-Path $KitDir 'pkgs\local'
if (Test-Path -LiteralPath $localDir) {
    $locals = @(Get-ChildItem -LiteralPath $localDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(exe|msi)$' })
    if ($locals.Count -gt 0) {
        Say ""
        Say ("=== 本地安装包（{0} 个）===" -f $locals.Count) 'Cyan'
        Say "  落点是安装器默认位置（通常是 C:\Program Files），脚本改不了" 'DarkGray'
        foreach ($f in $locals) {
            Say ("  " + $f.Name + "  -> 安装中 ...")
            $rc = -1
            if ($f.Extension -eq '.msi') {
                $p = Start-Process -FilePath 'msiexec.exe' `
                        -ArgumentList @('/i', ('"' + $f.FullName + '"'), '/qn', '/norestart') `
                        -PassThru -ErrorAction SilentlyContinue
                if ($p) {
                    $t0 = Get-Date
                    while (-not $p.WaitForExit(1000)) {
                        $sec = [int]((Get-Date) - $t0).TotalSeconds
                        if ($sec -ge 180) { break }
                        Write-Host ("`r    {0}  已等待 {1}/180 秒  " -f $f.Name, $sec) -NoNewline -ForegroundColor Gray
                    }
                    Write-Host ""
                    if ($p.HasExited) { $rc = $p.ExitCode }
                    else { try { $p.Kill() } catch { }; Say "    -> msiexec 超时（3 分钟），已终止" 'Yellow'; continue }
                }
            }
            else {
                foreach ($sw in @('/S', '/silent', '/quiet', '/VERYSILENT', '/SILENT')) {
                    $p = Start-Process -FilePath $f.FullName -ArgumentList $sw -PassThru -ErrorAction SilentlyContinue
                    if (-not $p) { continue }
                    $t0 = Get-Date
                    while (-not $p.WaitForExit(1000)) {
                        $sec = [int]((Get-Date) - $t0).TotalSeconds
                        if ($sec -ge 180) { break }
                        Write-Host ("`r    {0}（参数 {1}）已等待 {2}/180 秒  " -f $f.Name, $sw, $sec) -NoNewline -ForegroundColor Gray
                    }
                    Write-Host ""
                    if ($p.HasExited) {
                        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { $rc = $p.ExitCode; break }
                    }
                    else {
                        try { $p.Kill() } catch { }
                        Say "    -> 参数 $sw 超时（3 分钟），可能弹了窗口，已终止" 'Yellow'
                        $rc = -2
                        break
                    }
                }
            }
            if ($rc -eq 0 -or $rc -eq 3010) {
                $tail = if ($rc -eq 3010) { '（需重启）' } else { '' }
                Say ("    -> 成功" + $tail) 'Green'
                $results += [pscustomobject]@{ Id = $f.Name; Result = '成功'; Note = "本地包 exit $rc"; Where = '默认' }
            }
            elseif ($rc -eq -2) {
                $results += [pscustomobject]@{ Id = $f.Name; Result = '未处理'; Note = '需要交互，请手动双击'; Where = '' }
            }
            else {
                Say ("    -> 失败（exit {0}），请手动双击安装" -f $rc) 'Red'
                $results += [pscustomobject]@{ Id = $f.Name; Result = '失败'; Note = "本地包 exit $rc"; Where = '' }
            }
        }
    }
}

# ---------------------------------------------------------------- 关键包验收
# 网易UU远程是"装完就能远程接管"的前提，单独确认一次到底装上没有
$uuResult = $results | Where-Object { $_.Id -eq 'NetEase.UURemote' } | Select-Object -First 1
if ($uuResult) {
    Say ""
    Say "=== 关键包验收：网易UU远程 ===" 'Cyan'
    $uuHit = ''
    foreach ($cand in @(
            (Join-Path $env:ProgramFiles 'NetEase\UU\uu.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'NetEase\UU\uu.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\NetEase\UU\uu.exe'))) {
        if (Test-Path -LiteralPath $cand) { $uuHit = $cand; break }
    }
    if (-not $uuHit) {
        foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            $hit = Get-ItemProperty $rk -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -like '*UU*远程*' -or $_.DisplayName -like '*UU*Remote*' } |
                   Select-Object -First 1
            if ($hit) { $uuHit = [string]$hit.InstallLocation; break }
        }
    }

    if ($uuHit -or $uuResult.Result -in @('成功', '已安装')) {
        Say ("  [OK] 已安装" + $(if ($uuHit) { "：$uuHit" } else { '' })) 'Green'
        Say  "       打开它登录账号、设置固定密码 + 无人值守，之后就能从其他设备接进来" 'Gray'
        Say  "       设置好之后再关掉本窗口也不影响远程。" 'Gray'
    }
    else {
        Say "  [!!] 没装上 —— 现在还不能远程，必须先手动解决这一项" 'Red'
        Say  "       手动下载：https://uuyc.163.com/" 'Yellow'
        Say  "       装完再回来跑：powershell -ExecutionPolicy Bypass -File scripts\装软件.ps1 -Manifest packages-min.json" 'Yellow'
    }
}

# ---------------------------------------------------------------- 报告
$okCnt   = @($results | Where-Object { $_.Result -eq '成功' }).Count
$haveCnt = @($results | Where-Object { $_.Result -eq '已安装' }).Count
$fail    = @($results | Where-Object { $_.Result -eq '失败' -or $_.Result -eq '未处理' })
$onD     = @($results | Where-Object { $_.Result -eq '成功' -and $_.Where -eq 'D' }).Count
$onC     = @($results | Where-Object { $_.Result -eq '成功' -and $_.Where -eq 'C' }).Count

# 这次安装往 C 盘 Program Files 新增了哪些目录
$cDirsAfter = @()
foreach ($pf in @('C:\Program Files', 'C:\Program Files (x86)')) {
    if (Test-Path -LiteralPath $pf) {
        foreach ($d in (Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue)) {
            $cDirsAfter += ($pf + '|' + $d.Name)
        }
    }
}
$newOnC = @($cDirsAfter | Where-Object { $cDirsBefore -notcontains $_ })

$md = @()
$md += "# 软件安装结果（$Stamp）"
$md += ""
$md += "- 成功：$okCnt（其中明确落到 D 盘：$onD）"
$md += "- 已存在：$haveCnt"
$md += "- 失败/未处理：$($fail.Count)"
$md += "- 系统级安装根目录：``$InstallRoot``"
$md += ""
$md += "| 包 | 结果 | 装到 | 说明 |"
$md += "|---|---|---|---|"
foreach ($r in $results) {
    $w = '-'
    if ($r.Where) {
        if ($r.Where -eq 'D') { $w = 'D 盘' }
        elseif ($r.Where -eq 'C') { $w = 'C 盘' }
        elseif ($r.Where -eq '默认') { $w = '默认位置' }
        else { $w = '未知' }
    }
    $md += ("| {0} | {1} | {2} | {3} |" -f $r.Id, $r.Result, $w, $r.Note)
}
if ($newOnC.Count -gt 0) {
    $md += ""
    $md += "## 这次新增到 C:\Program Files 的目录"
    $md += ""
    $md += "这些是不认 ``--location`` 的安装器装出来的，想挪到 D 盘只能卸载重装或用目录链接。"
    $md += ""
    foreach ($x in $newOnC) { $md += ("- ``{0}``" -f ($x -replace '\|', '\')) }
}
if (Test-Path -LiteralPath $InstallRoot) {
    $dDirs = @(Get-ChildItem -LiteralPath $InstallRoot -Directory -ErrorAction SilentlyContinue)
    if ($dDirs.Count -gt 0) {
        $md += ""
        $md += "## $InstallRoot 下的目录（$($dDirs.Count) 个）"
        $md += ""
        foreach ($x in $dDirs) { $md += ("- ``{0}``" -f $x.Name) }
    }
}
if ($fail.Count -gt 0) {
    $md += ""
    $md += "## 需要手工处理"
    $md += ""
    foreach ($r in $fail) { $md += ("- {0}  —— {1}" -f $r.Id, $r.Note) }
}
$md | Set-Content -LiteralPath $LogMd -Encoding UTF8

Say ""
Say ("=== 完成：成功 {0}（D 盘 {1}） / 已存在 {2} / 失败 {3} ===" -f $okCnt, $onD, $haveCnt, $fail.Count) 'Cyan'
if ($newOnC.Count -gt 0) {
    Say ("有 {0} 个目录还是装到了 C:\Program Files，清单见表末。" -f $newOnC.Count) 'Yellow'
}
Say ("报告：{0}" -f $LogMd) 'Cyan'
if ($fail.Count -gt 0) { Say "失败项稍后重跑本脚本即可补装（已装的会跳过）。" 'Yellow' }
exit 0
