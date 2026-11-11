#requires -Version 5.1
<#
    把 Windows 安装镜像放到已有的 WePE 维护盘上（不破坏 PE）
    ============================================================
    适用场景：U 盘已经用 WePE 做过维护盘（可见分区 + 末尾隐藏分区），
              不想为了装系统把整个 U 盘清掉重做成 Ventoy。

    本脚本只做三件事，不碰任何分区、不格式化：
      1. 确认目标盘确实是 WePE 盘（根目录有 WEPE.ICO 或卷标含 PE）
      2. 把 ISO 拷到可见分区根目录
      3. 把应答文件拷成根目录的 autounattend.xml

    装系统时：从 WePE 启动 → 右键 ISO「挂载」→ 运行 setup.exe

    用法：
      powershell -ExecutionPolicy Bypass -File 05-拷到WePE盘.ps1
      powershell -ExecutionPolicy Bypass -File 05-拷到WePE盘.ps1 -DryRun
      powershell -ExecutionPolicy Bypass -File 05-拷到WePE盘.ps1 -DriveLetter E
#>
[CmdletBinding()]
param(
    [Alias('IsoPath')]
    [string]$Iso = '',
    [string]$AnswerFile = 'autounattend-保留恢复分区-社区重制版.xml',
    [string]$DriveLetter = '',
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'wepe-copy' | Out-Null
Write-Head "把安装镜像放到 WePE 盘（不动分区）"

if (-not (Assert-Admin)) { Stop-KitLog; exit 2 }

# ================================================================= 0 前置
if (-not $Iso) { $Iso = $IsoPath }
if (-not $Iso) { $Iso = Find-KitIso }

if (-not $Iso -or -not (Test-Path -LiteralPath $Iso)) {
    Write-Err ("找不到 ISO: " + $(if ($Iso) { $Iso } else { '(未配置，也没在工程包/数据盘里找到)' }))
    Write-Info '把 ISO 放到工程包目录或数据盘下，或改 kit.config.json 的 isoPath'
    Stop-KitLog; exit 1
}
$isoItem = Get-Item -LiteralPath $Iso

$ansPath = Join-Path $script:KitRoot $AnswerFile
if (-not (Test-Path -LiteralPath $ansPath)) {
    Write-Err ("找不到应答文件: " + $ansPath)
    Stop-KitLog; exit 1
}
if (-not (Test-XmlFile -Path $ansPath)) {
    Write-Err "应答文件 XML 语法有错，先修好再拷。"
    Stop-KitLog; exit 1
}

Write-Info ("ISO     : {0}  ({1})" -f $isoItem.Name, (Format-Human $isoItem.Length))
Write-Info ("应答文件: {0}" -f $AnswerFile)

# ================================================================= 1 找 U 盘
Write-Step "1. 找 WePE 盘"

$usbList = @(Get-UsbDisks)
if ($usbList.Count -eq 0) {
    Write-Err "没检测到 U 盘。把 WePE 盘插上再跑。"
    Stop-KitLog; exit 1
}

foreach ($u in $usbList) {
    Write-Info ("  磁盘{0}  {1}  {2}  盘符 {3}  卷标 {4}" -f $u.Number, $u.Friendly,
        (Format-Human $u.SizeBytes), $(if ($u.DriveLetter) { $u.DriveLetter } else { '无' }), $u.Label)
}

$target = $null
if (-not $DriveLetter -and $WepeDrive) { $DriveLetter = $WepeDrive }
if ($DriveLetter) {
    $target = $usbList | Where-Object { $_.DriveLetter -eq $DriveLetter.TrimEnd(':').ToUpper() } | Select-Object -First 1
} elseif ($usbList.Count -eq 1) {
    $target = $usbList[0]
} else {
    Write-Err "插了不止一个 U 盘，用 -DriveLetter 指定。"
    Stop-KitLog; exit 1
}

if (-not $target) {
    Write-Err "没选中 U 盘。"
    Stop-KitLog; exit 1
}
if (-not $target.DriveLetter) {
    Write-Err "这个 U 盘没有盘符，先给它分一个（磁盘管理）。"
    Stop-KitLog; exit 1
}

$usbRoot = $target.DriveLetter + ':\'
Write-Ok ("目标盘: {0}:  {1}  {2}  卷标 {3}" -f $target.DriveLetter, $target.Friendly,
    (Format-Human $target.SizeBytes), $target.Label)

# ================================================================= 2 确认是 WePE
Write-Step "2. 确认这是 WePE 盘"

$isWepe = $false
$why = ''
if (Test-Path -LiteralPath (Join-Path $usbRoot 'WEPE.ICO')) { $isWepe = $true; $why = '根目录有 WEPE.ICO' }
elseif ($target.Label -match 'PE') { $isWepe = $true; $why = "卷标含 PE（$($target.Label)）" }

$hidden = @()
try {
    $hidden = @(Get-Partition -DiskNumber $target.Number -ErrorAction Stop |
        Where-Object { $_.Type -eq 'Unknown' -or -not $_.DriveLetter })
} catch { }
if ($hidden.Count -gt 0) { $why += $(if ($why) { '，' } else { '' }) + ("有 {0} 个隐藏分区" -f $hidden.Count) }

if ($isWepe) {
    Write-Ok ("是 WePE 盘（{0}）—— 不会动分区" -f $why)
} else {
    Write-Warn ("没找到明显的 WePE 特征（{0}）" -f $why)
    Write-Warn "如果这不是 WePE 盘，装系统时可能无法从这个盘启动。"
    if (-not (Read-YesNo "仍然继续把文件拷进去吗？")) { Stop-KitLog; exit 1 }
}

# 如果已经是 Ventoy 盘，提醒走 04-做U盘.ps1 更合适
if (Test-Path -LiteralPath (Join-Path $usbRoot 'ventoy')) {
    Write-Warn "这个盘看起来装过 Ventoy —— 那种情况直接用 04-做U盘.ps1 更合适（它只覆盖同名 ISO，也不格式化）。"
    if (-not (Read-YesNo "仍要按 WePE 方式拷文件？")) { Stop-KitLog; exit 1 }
}

# ================================================================= 3 空间
Write-Step "3. 检查空间"

$free = 0
try { $free = (Get-Volume -DriveLetter $target.DriveLetter).SizeRemaining } catch { }
$need = $isoItem.Length + 20MB
Write-Info ("可用 {0} / 需要 {1}" -f (Format-Human $free), (Format-Human $need))
if ($free -lt $need) {
    Write-Err ("空间不够。还差 {0}，先清点东西出来。" -f (Format-Human ($need - $free)))
    Stop-KitLog; exit 1
}

# ================================================================= 4 拷贝
Write-Step "4. 拷贝文件"

$isoDest = Join-Path $usbRoot $isoItem.Name
$ansDest = Join-Path $usbRoot 'autounattend.xml'

if ($DryRun) {
    Write-Info ("[演练] {0}  ->  {1}" -f $isoItem.FullName, $isoDest)
    Write-Info ("[演练] {0}  ->  {1}" -f $ansPath, $ansDest)
    Write-Info "[演练] 不写入任何文件"
    Stop-KitLog; exit 0
}

# ---- ISO：先检查 U 盘上已有的旧文件（大小相同 ≠ 内容完整，必须比哈希）----
$copyIso = $true
$verified = $false
if (Test-Path -LiteralPath $isoDest) {
    if ((Get-Item -LiteralPath $isoDest).Length -eq $isoItem.Length) {
        Write-Info "U 盘上已有同名 ISO，校验是否与源一致（读 6 GB，约几分钟）..."
        try {
            $hashUsb = Get-Sha256WithProgress -Path $isoDest -Label '(U盘侧)'
            $hashSrc = Get-Sha256WithProgress -Path $isoItem.FullName -Label '(源)'
            $same = ($hashUsb -eq $hashSrc)
        } catch { $same = $false }
        if ($same) {
            $copyIso = $false
            $verified = $true
            Write-Ok "U 盘上的 ISO 与源文件 SHA256 一致，跳过拷贝"
        } else {
            Write-Warn "U 盘上的 ISO 内容不完整或不一致（大小相同也可能是上次拷了一半），重新拷贝"
        }
    } else {
        Write-Warn "U 盘上的 ISO 大小与源不同，重新拷贝"
    }
    if ($copyIso) {
        Remove-Item -LiteralPath $isoDest -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $isoDest) {
            Write-Err "旧 ISO 删不掉（可能正被占用），重插 U 盘后重跑本脚本。"
            Stop-KitLog; exit 1
        }
    }
}

if ($copyIso) {
    Write-Info ("正在拷贝 ISO（{0}），每秒显示百分比进度..." -f (Format-Human $isoItem.Length))
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $src = $null; $dst = $null
    try {
        $src = [IO.File]::OpenRead($isoItem.FullName)
        $dst = [IO.File]::Open($isoDest, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        $buf = New-Object byte[] (4MB)
        $total = $src.Length
        $done = [long]0
        $lastTick = [DateTime]::MinValue
        while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
            $dst.Write($buf, 0, $n)
            $done += $n
            if (((Get-Date) - $lastTick).TotalMilliseconds -ge 500) {
                $lastTick = Get-Date
                $pct = [Math]::Round($done * 100.0 / $total, 1)
                $mbps = if ($t0.Elapsed.TotalSeconds -gt 0.5) { [math]::Round($done / 1MB / $t0.Elapsed.TotalSeconds, 1) } else { 0 }
                Write-ProgressLine ("  拷贝 {0,5:N1}%  {1} / {2}  {3} MB/s  已用 {4:N0} 秒" -f `
                    $pct, (Format-Human $done), (Format-Human $total), $mbps, $t0.Elapsed.TotalSeconds)
            }
        }
        Write-Host ""
        $dst.Flush()
    } catch {
        if ($dst) { $dst.Dispose() }
        if ($src) { $src.Dispose() }
        Remove-Item -LiteralPath $isoDest -Force -ErrorAction SilentlyContinue
        Write-Err ("拷贝失败: " + $_.Exception.Message)
        Write-Warn "如果是进度不动后报错：拔插一次 U 盘再重跑本脚本。"
        Stop-KitLog; exit 1
    }
    if ($dst) { $dst.Dispose() }
    if ($src) { $src.Dispose() }
    $sec = [int]$t0.Elapsed.TotalSeconds
    $mbps = if ($sec -gt 0) { [math]::Round($isoItem.Length / 1MB / $sec, 1) } else { 0 }
    Write-Ok ("ISO 拷贝完成，用时 {0} 秒（{1} MB/s）" -f $sec, $mbps)
}

# ---- 校验：大小 + SHA256（读回 U 盘上的 6 GB，几分钟）----
if (-not $verified) {
    if ((Get-Item -LiteralPath $isoDest).Length -ne $isoItem.Length) {
        Write-Err "拷贝后大小不一致，U 盘可能有坏块。拔插 U 盘后重跑本脚本。"
        Stop-KitLog; exit 1
    }
    Write-Info "校验 U 盘上的 ISO（读回 6 GB 做 SHA256，实时显示进度）..."
    $usbHash = Get-Sha256WithProgress -Path $isoDest -Label '(U盘侧)'
    $srcHash = Get-Sha256WithProgress -Path $isoItem.FullName -Label '(源)'
    if (-not $usbHash -or $usbHash -ne $srcHash) {
        Write-Err "SHA256 校验不一致——U 盘写入有坏块。拔插 U 盘后重跑本脚本。"
        Stop-KitLog; exit 1
    }
    Write-Ok "SHA256 校验通过，镜像完整"
}

# 应答文件：先按本机配置渲染占位符，再和 U 盘上的比内容
$kitName = Split-Path -Leaf $script:KitRoot
$rawAns = Get-Content -LiteralPath $ansPath -Raw -Encoding UTF8
$ansText = $rawAns.Replace('__USER__', $LocalUserName).Replace('__COMPUTERNAME__', $LocalComputerName).Replace('__KITNAME__', $kitName)
$generatedPath = Join-Path $script:KitRoot 'autounattend.generated.xml'

if ($DryRun) {
    Write-Info ("[演练] 会按本机配置渲染 {0} -> {1}" -f $ansPath, $ansDest)
} else {
    [IO.File]::WriteAllText($generatedPath, $ansText, (New-Object Text.UTF8Encoding($true)))
    Write-Info ("渲染结果已留存: " + $generatedPath)
    if (Test-Path -LiteralPath $ansDest) {
        $oldText = Get-Content -LiteralPath $ansDest -Raw -Encoding UTF8
        if ($oldText -eq $ansText) {
            Write-Ok "autounattend.xml 已是最新，跳过"
        } else {
            Copy-Item -LiteralPath $ansDest -Destination ($ansDest + '.bak') -Force
            [IO.File]::WriteAllText($ansDest, $ansText, (New-Object Text.UTF8Encoding($true)))
            Write-Ok "autounattend.xml 已更新（旧的存为 .bak）"
        }
    } else {
        [IO.File]::WriteAllText($ansDest, $ansText, (New-Object Text.UTF8Encoding($true)))
        Write-Ok "autounattend.xml 已放到 U 盘根目录"
    }
}

# ================================================================= 5 指引
Write-Step "5. 装系统时怎么做"

Write-Host ""
Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │  U 盘已就绪，WePE 和它的隐藏分区完全没动               │" -ForegroundColor Cyan
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. 重启，开机按 F12，选 U 盘（UEFI 启动）进 WePE" -ForegroundColor Gray
Write-Host "  2. 进 PE 桌面后，打开「此电脑」，找到 $($target.DriveLetter): 盘" -ForegroundColor Gray
Write-Host "  3. 右键 $($isoItem.Name) → 「挂载」（或双击，PE 会自己挂虚拟光驱）" -ForegroundColor Gray
Write-Host "  4. 运行挂载出来的 setup.exe" -ForegroundColor Gray
Write-Host "  5. 应答文件在 $($target.DriveLetter):\autounattend.xml，安装程序会自动读" -ForegroundColor Gray
Write-Host ""
Write-Host "  如果第 4 步之后仍然让你「选择要安装的操作系统」：" -ForegroundColor Yellow
Write-Host "    说明应答文件没被自动读取。此时按 Shift+F10 开命令行，执行：" -ForegroundColor Yellow
Write-Host "      <挂载盘符>:\setup.exe /unattend:$($target.DriveLetter):\autounattend.xml" -ForegroundColor White
Write-Host ""
Write-Host "  本次应答文件做什么：" -ForegroundColor Gray
Write-Host "    · 只格式化应答文件里指定的系统分区，ESP / MSR / 厂商恢复分区一律不碰" -ForegroundColor Gray
Write-Host "    · 跳过 OOBE 的联网、账号、隐私页" -ForegroundColor Gray
Write-Host "    · 首次登录自动在 D~H 盘里找工程包目录并执行 bootstrap.cmd" -ForegroundColor Gray
Write-Host ""

Stop-KitLog
exit 0
