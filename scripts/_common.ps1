#requires -Version 5.1
<#
    公共函数库 —— 不单独运行，由其他脚本 dot-source 引入。
    ============================================================
    约定：
      · 不改 [Console]::OutputEncoding（中文 Windows 控制台是 936，强改会乱码）
      · 所有可能等待用户输入的地方都必须有 try/catch，非交互运行时立刻返回 false
      · 危险动作统一走 Invoke-DiskpartScript，-DryRun 时只打印不执行
#>

$ErrorActionPreference = 'Stop'

$script:KitRoot = Split-Path -Parent $PSScriptRoot
$script:LogFile = $null

$script:DellRecoveryGpt    = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$script:DellRecoveryLabels = @('WINRETOOLS', 'Image', 'DELLSUPPORT')

# ------------------------------------------------------------------ 输出
function Write-Head {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor Cyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    $n = [Math]::Max(2, 58 - $Text.Length)
    Write-Host ""
    Write-Host ("-- " + $Text + " " + ("-" * $n)) -ForegroundColor Cyan
}

function Write-Ok   { param([string]$Text) Write-Host ("  [OK]   " + $Text) -ForegroundColor Green }
function Write-Info { param([string]$Text) Write-Host ("  " + $Text) }
function Write-Warn { param([string]$Text) Write-Host ("  [警告] " + $Text) -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host ("  [错误] " + $Text) -ForegroundColor Red }
function Write-Skip { param([string]$Text) Write-Host ("  [跳过] " + $Text) -ForegroundColor DarkGray }
function Write-Danger {
    param([string]$Text)
    Write-Host ""
    Write-Host ("  !!! " + $Text) -ForegroundColor White -BackgroundColor DarkRed
}

# ------------------------------------------------------------------ 权限
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Assert-Admin {
    param([string]$Hint = '请通过「开始.cmd」入口运行（会自动提权），或右键以管理员身份运行本脚本。')
    if (Test-Admin) { return $true }
    Write-Err "本脚本需要管理员权限。"
    Write-Info $Hint
    return $false
}

# ------------------------------------------------------------------ 日志
function Start-KitLog {
    param([string]$Name)
    $dir = Join-Path $script:KitRoot 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = Join-Path $dir ("{0}_{1}.log" -f $Name, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { Start-Transcript -LiteralPath $script:LogFile -Force | Out-Null } catch { }
    return $script:LogFile
}

function Stop-KitLog {
    try { Stop-Transcript | Out-Null } catch { }
}

# ------------------------------------------------------------------ 交互
function Read-ConfirmText {
    <#  要求用户原样输入 $Expect 才返回 $true；非交互环境安全返回 $false  #>
    param([string]$Prompt, [string]$Expect, [int]$Tries = 3)
    for ($i = 1; $i -le $Tries; $i++) {
        $ans = $null
        try { $ans = Read-Host $Prompt } catch { return $false }
        if ($null -eq $ans) { return $false }
        if ($ans.Trim() -ceq $Expect) { return $true }
        Write-Warn ("输入不一致（第 {0}/{1} 次），需要一字不差地输入：{2}" -f $i, $Tries, $Expect)
    }
    return $false
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    if ($Default) { $suffix = '[Y/n]' } else { $suffix = '[y/N]' }
    $ans = $null
    try { $ans = Read-Host ("{0} {1}" -f $Prompt, $suffix) } catch { return $false }
    if ($null -eq $ans) { return $false }
    $ans = $ans.Trim()
    if ($ans -eq '') { return $Default }
    return ($ans -match '^(y|yes|是)$')
}

function Wait-Countdown {
    <#  倒计时，期间按任意键返回 $false（表示取消）  #>
    param([int]$Seconds = 10, [string]$Message = '即将开始执行')
    Write-Host ""
    for ($s = $Seconds; $s -gt 0; $s--) {
        Write-Host ("`r  {0}，{1} 秒后继续；按任意键取消 ... " -f $Message, $s) -NoNewline -ForegroundColor Yellow
        try {
            if ([Console]::KeyAvailable) {
                $null = [Console]::ReadKey($true)
                Write-Host ""
                Write-Warn "已取消（未做任何修改）。"
                return $false
            }
        } catch { }
        Start-Sleep -Milliseconds 1000
    }
    Write-Host ""
    return $true
}

# ------------------------------------------------------------------ 格式化
function Format-Human {
    param([double]$Bytes)
    $u = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt 4) { $Bytes /= 1024.0; $i++ }
    if ($i -eq 0) { return ("{0:N0} {1}" -f $Bytes, $u[$i]) }
    return ("{0:N2} {1}" -f $Bytes, $u[$i])
}

# ------------------------------------------------------------------ 进度
function Write-ProgressLine {
    <#  单行实时刷新：\r 覆盖当前行，行尾补空格清掉上一行残留  #>
    param([string]$Text)
    if ($Text.Length -gt 96) { $Text = $Text.Substring(0, 96) }
    $pad = [Math]::Max(0, 100 - $Text.Length)
    Write-Host ("`r" + $Text + (" " * $pad)) -NoNewline -ForegroundColor Gray
}

function Get-Sha256WithProgress {
    <#
        分块计算 SHA256，单行显示百分比 / 已读 / 速度。
        Get-FileHash 读大文件（6 GB ISO、出厂镜像）时完全静默，
        看起来像卡死；这里每 250ms 刷新一次进度行。
        以共享读方式打开，文件被其他进程占用时也能算。
    #>
    param([string]$Path, [string]$Label = '', [switch]$KeepLine)
    $algo = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
    try {
        $total = $fs.Length
        $buf = New-Object byte[] (4MB)
        $done = [long]0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $last = [DateTime]::MinValue
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $null = $algo.TransformBlock($buf, 0, $n, $null, 0)
            $done += $n
            if (((Get-Date) - $last).TotalMilliseconds -ge 250 -or $done -eq $total) {
                $last = Get-Date
                $pct = if ($total -gt 0) { [Math]::Round($done * 100.0 / $total, 1) } else { 100.0 }
                $mbps = ($done / 1MB) / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                Write-ProgressLine ("  SHA256 {0,5:N1}%  {1} / {2}  {3:N0} MB/s  {4}" -f `
                    $pct, (Format-Human $done), (Format-Human $total), $mbps, $Label)
            }
        }
        $null = $algo.TransformFinalBlock($buf, 0, 0)
        if (-not $KeepLine) { Write-Host "" }
        return ([BitConverter]::ToString($algo.Hash) -replace '-', '')
    }
    finally {
        $fs.Dispose()
        $algo.Dispose()
    }
}

# ------------------------------------------------------------------ 磁盘
function Get-SystemDiskNumber {
    $letter = $env:SystemDrive.TrimEnd(':')
    $p = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { return [int]$p.DiskNumber }
    $d = Get-Disk | Where-Object { $_.IsSystem -or $_.IsBoot } | Select-Object -First 1
    if ($d) { return [int]$d.Number }
    return $null
}

function Get-DellRecoveryPartitions {
    <#  只返回 GPT 类型为 Recovery 的分区；IsDell 标记卷标是否属于 Dell 三件套  #>
    param([int]$DiskNumber)
    $list = @()
    $parts = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
    foreach ($p in $parts) {
        $gt = ''
        try { $gt = ([string]$p.GptType).Trim('{', '}').ToLower() } catch { }
        if ($gt -ne $script:DellRecoveryGpt) { continue }
        $label = ''
        try {
            $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if ($v) { $label = [string]$v.FileSystemLabel }
        } catch { }
        $list += [pscustomobject]@{
            PartitionNumber = [int]$p.PartitionNumber
            Label           = $label
            SizeBytes       = [int64]$p.Size
            Offset          = [int64]$p.Offset
            DriveLetter     = [string]$p.DriveLetter
            IsDell          = ($script:DellRecoveryLabels -contains $label)
        }
    }
    return ($list | Sort-Object Offset)
}

function Get-UsbDisks {
    <#  返回所有 USB 磁盘及其第一个有盘符的卷  #>
    $out = @()
    foreach ($d in (Get-Disk | Where-Object { $_.BusType -eq 'USB' })) {
        $vol = $null
        try {
            $part = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter } | Select-Object -First 1
            if ($part) { $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue }
        } catch { }
        $out += [pscustomobject]@{
            Number      = [int]$d.Number
            Friendly    = [string]$d.FriendlyName
            SizeBytes   = [int64]$d.Size
            DriveLetter = if ($vol) { [string]$vol.DriveLetter } else { '' }
            Label       = if ($vol) { [string]$vol.FileSystemLabel } else { '' }
        }
    }
    return $out
}

function Invoke-DiskpartScript {
    <#  把多行 diskpart 命令写成临时脚本执行；-DryRun 只回显  #>
    param([string]$Content, [switch]$DryRun)
    $lines = ($Content.Trim() -split "`r?`n")
    if ($DryRun) {
        Write-Host "  ----- diskpart 命令（演练，不执行）-----" -ForegroundColor DarkGray
        foreach ($l in $lines) { Write-Host ("      " + $l) -ForegroundColor DarkGray }
        Write-Host "  ---------------------------------------" -ForegroundColor DarkGray
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
    }
    $tmp = Join-Path $env:TEMP ("diskpart_{0}.txt" -f (Get-Date -Format 'HHmmssfff'))
    try {
        Set-Content -LiteralPath $tmp -Value $lines -Encoding ASCII
        $out = (& diskpart /s $tmp 2>&1 | Out-String)
        $code = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $code; Output = $out }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ ISO / WIM
function Get-IsoImageNames {
    <#
        挂载 ISO，读取 sources\install.wim|esd 的映像名清单。
        两条路：
          1. 自己解析 WIM 头部（快，但遇上压缩存储的 XML 会失败）
          2. dism /Get-WimInfo（需要管理员，兼容性最好）
        返回 @{ Ok=; Drive=; File=; Names=@(); Error= }
    #>
    param([string]$IsoPath)

    $result = [pscustomobject]@{ Ok = $false; Drive = ''; File = ''; Names = @(); Error = '' }
    $img = $null
    try {
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $vol = $img | Get-Volume -ErrorAction Stop
        if (-not $vol -or -not $vol.DriveLetter) { throw 'ISO 已挂载但拿不到盘符' }
        $drive = [string]$vol.DriveLetter
        $result.Drive = $drive

        $src = Join-Path ($drive + ':\') 'sources'
        $file = Get-ChildItem -LiteralPath $src -ErrorAction Stop |
                Where-Object { $_.Name -match '^install\.(wim|esd)$' } |
                Select-Object -First 1
        if (-not $file) { throw "ISO 的 sources 目录里没有 install.wim / install.esd" }
        $result.File = $file.Name

        $names = @(Get-WimImageNames -Path $file.FullName)
        if ($names.Count -eq 0) {
            Write-Info "  头部解析没读到映像名（XML 可能是压缩存储），改用 DISM ..."
            $names = @(Get-WimImageNamesViaDism -Path $file.FullName)
        }
        if ($names.Count -eq 0) { throw '读不出映像名（XML 压缩存储，且 DISM 也不可用）' }
        $result.Names = $names
        $result.Ok = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($img) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null }
    }
    return $result
}

function Get-WimImageNamesViaDism {
    param([string]$Path)
    $out = & dism /Get-WimInfo /WimFile:$Path 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return @() }
    $names = @()
    foreach ($line in ($out -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*(名称|Name)\s*[:：]\s*(.+?)\s*$')
        if ($m.Success) { $names += $m.Groups[2].Value }
    }
    return $names
}

function Get-WimImageNames {
    <#
        解析 WIM/ESD 头部：XML 资源的位置写在头部偏移 80（Offset）与 88（Size）。
        XML 通常在文件尾部；头部读不到时再从末尾 8MB 兜底找。
    #>
    param([string]$Path, [int]$ScanBytes = 8MB)

    $blobs = @()
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $len = [int64]$fs.Length

        $h = New-Object byte[] 208
        $null = $fs.Read($h, 0, 208)
        if ($h[0] -eq 0x4D -and $h[1] -eq 0x53) {          # "MS"
            $xmlOff  = [BitConverter]::ToInt64($h, 80)
            $xmlSize = [BitConverter]::ToInt64($h, 88)
            if ($xmlOff -gt 0 -and $xmlOff -lt $len) {
                $take = [int64][Math]::Min([Math]::Max($xmlSize, 4096), [int64]$ScanBytes)
                if (($xmlOff + $take) -gt $len) { $take = [int64]($len - $xmlOff) }
                if ($take -gt 0) {
                    $fs.Position = $xmlOff
                    $b = New-Object byte[] ([int]$take)
                    $null = $fs.Read($b, 0, [int]$take)
                    $blobs += , $b
                }
            }
        }

        $tailLen = [int][Math]::Min([int64]$ScanBytes, $len)
        if ($tailLen -gt 0) {
            $fs.Position = $len - $tailLen
            $tb = New-Object byte[] $tailLen
            $null = $fs.Read($tb, 0, $tailLen)
            $blobs += , $tb
        }
    }
    finally {
        if ($fs) { $fs.Dispose() }
    }

    foreach ($blob in $blobs) {
        foreach ($enc in @([System.Text.Encoding]::Unicode, [System.Text.Encoding]::UTF8)) {
            $text = $enc.GetString($blob)
            $m = [regex]::Match($text, '<WIM>[\s\S]*?</WIM>')
            if (-not $m.Success) { continue }
            try {
                $xml = [xml]$m.Value
                $names = @()
                foreach ($im in $xml.WIM.IMAGE) {
                    $dn = [string]$im.DISPLAYNAME
                    if (-not $dn) { $dn = [string]$im.NAME }
                    if ($dn) { $names += $dn.Trim() }
                }
                if ($names.Count -gt 0) { return $names }
            }
            catch { continue }
        }
    }
    return @()
}

# ------------------------------------------------------------------ 出厂镜像
$script:FactoryVolDirs = @{
    'Image'       = 'P5_Image'
    'DELLSUPPORT' = 'P6_DELLSUPPORT'
    'WINRETOOLS'  = 'P4_WINRETOOLS'
}

function Resolve-FactoryPath {
    <#
        MANIFEST.json 里 rel 带卷标前缀。磁盘上的落点有两种形态：
            Image        -> P5_Image\Image\install.swm      （保留整个 rel）
            DELLSUPPORT  -> P6_DELLSUPPORT\sources\...      （去掉卷标前缀）
            WINRETOOLS   -> P4_WINRETOOLS\xxx.marker        （去掉卷标前缀）
        所以两个候选都试，谁存在用谁；都不存在时返回第一个用于报错。
    #>
    param([string]$FactoryRoot, $Entry)
    $vol = [string]$Entry.vol
    $rel = [string]$Entry.rel
    if (-not $rel) { return $null }
    $base = $script:FactoryVolDirs[$vol]
    if (-not $base) { return $null }
    $baseDir = Join-Path $FactoryRoot $base

    $sub = $rel
    if ($sub.StartsWith($vol + '\')) { $sub = $sub.Substring($vol.Length + 1) }

    $c1 = Join-Path $baseDir $sub
    if (Test-Path -LiteralPath $c1) { return $c1 }
    $c2 = Join-Path $baseDir $rel
    if (Test-Path -LiteralPath $c2) { return $c2 }
    return $c1
}

function Test-XmlFile {
    param([string]$Path)
    try {
        $x = New-Object System.Xml.XmlDocument
        $x.XmlResolver = $null
        $x.Load($Path)
        return $true
    } catch { return $false }
}

# ------------------------------------------------------------------ 本机配置
function Get-KitConfig {
    <#
        读取工程包根目录的 kit.config.json；文件不存在时按空模板生成。
        参数:
            Root: 工程包根目录，默认 $script:KitRoot
        返回值:
            PSCustomObject，含 userName/computerName/dataRoot/migrationRoot/
            backupRoot/installRoot/isoPath/wepeDrive 八个字段，空串表示自动推断
        备注:
            解析失败只告警并按空配置继续，避免一个坏 JSON 让所有脚本都跑不起来。
    #>
    param([string]$Root = $script:KitRoot)

    $path = Join-Path $Root 'kit.config.json'
    $keys = @('userName', 'computerName', 'dataRoot', 'migrationRoot',
              'backupRoot', 'installRoot', 'isoPath', 'wepeDrive')
    $cfg = [ordered]@{}
    foreach ($k in $keys) { $cfg[$k] = '' }

    if (Test-Path -LiteralPath $path) {
        try {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $keys) {
                $v = $json.PSObject.Properties[$k]
                if ($v -and $v.Value) { $cfg[$k] = [string]$v.Value }
            }
        }
        catch {
            Write-Warn ("kit.config.json 解析失败，按默认值继续：" + $_.Exception.Message)
        }
    }
    else {
        try {
            $text = ([ordered]@{
                _说明         = '本机配置。字段留空表示自动推断；路径用绝对路径（反斜杠写成双反斜杠）。'
                userName      = ''
                computerName  = ''
                dataRoot      = ''
                migrationRoot = ''
                backupRoot    = ''
                installRoot   = ''
                isoPath       = ''
                wepeDrive     = ''
            } | ConvertTo-Json)
            [IO.File]::WriteAllText($path, ($text + "`r`n"), (New-Object Text.UTF8Encoding($true)))
            Write-Info ("已生成本机配置模板: " + $path)
            Write-Info "按需要填写 migrationRoot 等字段，重跑本脚本即可生效。"
        }
        catch {
            Write-Warn ("无法生成 kit.config.json：" + $_.Exception.Message)
        }
    }
    return [pscustomobject]$cfg
}

function Assert-MigrationRoot {
    <#  链接类脚本的前置闸门：迁移根必须已配置；未配置时打印填写指引并返回 $false  #>
    if ($script:MigrationRoot) { return $true }
    Write-Err "没有配置迁移根目录：kit.config.json 的 migrationRoot 为空。"
    Write-Info "链接相关脚本要靠它把 %MIGROOT% 展开成真实路径。"
    Write-Info ("文件: " + (Join-Path $script:KitRoot 'kit.config.json'))
    Write-Info '示例: "migrationRoot": "D:\\migration\\C\\Users\\<用户名>"'
    return $false
}

function Find-KitIso {
    <#
        在工程包目录与数据盘浅层（最深 2 层）找 Windows 安装 ISO。
        返回值: 唯一候选的完整路径；没候选或有歧义时返回空串并打印候选清单
        备注: 只认文件名像 Windows 安装盘的 ISO，避免把 Linux / Matlab 之类
              误写进 U 盘；宁可不猜，也不猜错。
    #>
    $all = @()
    foreach ($r in @($script:KitRoot, $DataRoot) | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $all += @(Get-ChildItem -LiteralPath $r -Filter '*.iso' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)
    }
    if ($all.Count -eq 0) { return '' }

    $win = @($all | Where-Object { $_.Name -match '(?i)(windows|win10|win11|zh-cn)' })
    if ($win.Count -eq 1) { return $win[0].FullName }
    if ($win.Count -gt 1) {
        $ltsc = @($win | Where-Object { $_.Name -match '(?i)(ltsc|iot)' })
        if ($ltsc.Count -eq 1) {
            Write-Info ("自动选中 LTSC 版: " + $ltsc[0].Name)
            return $ltsc[0].FullName
        }
        Write-Warn ("找到 {0} 支像 Windows 安装盘的 ISO，无法确定用哪支：" -f $win.Count)
        foreach ($f in $win) { Write-Info ("    " + $f.FullName) }
        Write-Info '请用 -Iso 指定，或把要用的那支填进 kit.config.json 的 isoPath'
        return ''
    }
    if ($all.Count -eq 1) { return $all[0].FullName }
    Write-Warn ("找到 {0} 支 ISO，但没有一支像 Windows 安装盘：" -f $all.Count)
    foreach ($f in $all) { Write-Info ("    " + $f.FullName) }
    Write-Info '请用 -Iso 指定，或把要用的那支填进 kit.config.json 的 isoPath'
    return ''
}

# 配置在文件末尾加载：Get-KitConfig 依赖上面的 Write-*；dot-source 后各脚本可直接用这些变量
$script:KitCfg = Get-KitConfig
if (-not $script:KitCfg.userName) { $script:KitCfg.userName = $env:USERNAME }
if (-not $script:KitCfg.computerName) { $script:KitCfg.computerName = $env:COMPUTERNAME }
if (-not $script:KitCfg.dataRoot) {
    $kitQualifier = Split-Path -Qualifier $script:KitRoot
    if ($kitQualifier) { $script:KitCfg.dataRoot = $kitQualifier + '\' }
}
if (-not $script:KitCfg.backupRoot)  { $script:KitCfg.backupRoot = Join-Path $script:KitRoot 'backup' }
if (-not $script:KitCfg.installRoot) { $script:KitCfg.installRoot = Join-Path $script:KitCfg.dataRoot 'Programs' }

$LocalUserName     = $script:KitCfg.userName
$LocalComputerName = $script:KitCfg.computerName
$DataRoot          = $script:KitCfg.dataRoot
$MigrationRoot     = $script:KitCfg.migrationRoot
$BackupRoot        = $script:KitCfg.backupRoot
$InstallRoot       = $script:KitCfg.installRoot
$IsoPath           = $script:KitCfg.isoPath
$WepeDrive         = $script:KitCfg.wepeDrive
