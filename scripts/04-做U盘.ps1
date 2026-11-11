#requires -Version 5.1
<#
    制作 Windows 安装 U 盘（Ventoy + ISO + 应答文件）
    ============================================================
    只干三件事：
      1. 确认 U 盘已用 Ventoy 做好（没做就自动下载 Ventoy 并安装）
      2. 把 ISO 拷进 U 盘
      3. 把应答文件拷到 U 盘根目录，改名 autounattend.xml

    安全：
      · Ventoy 安装会清空整只 U 盘 —— 三道确认（y / 手输盘符 / 10 秒倒计时）
      · 已装 Ventoy 的盘不会再格式化，只覆盖同名 ISO 与应答文件
      · -DryRun 只检查环境并打印计划，一个字都不写

    用法：
        开始.cmd  →  4
        或： powershell -ExecutionPolicy Bypass -File 04-做U盘.ps1
            powershell -ExecutionPolicy Bypass -File 04-做U盘.ps1 -DryRun
            powershell -ExecutionPolicy Bypass -File 04-做U盘.ps1 -DriveLetter E
#>
[CmdletBinding()]
param(
    [Alias('IsoPath')]
    [string]$Iso = '',
    [string]$AnswerFile = 'autounattend-保留恢复分区-社区重制版.xml',
    [string]$DriveLetter = '',
    [switch]$DryRun,
    [switch]$NoDownload
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'make-usb' | Out-Null
Write-Head "制作安装 U 盘"

# ================================================================= 0 前置
if (-not (Assert-Admin)) { Stop-KitLog; exit 2 }

if (-not $Iso) { $Iso = $IsoPath }
if (-not $Iso) { $Iso = Find-KitIso }

if (-not $Iso -or -not (Test-Path -LiteralPath $Iso)) {
    Write-Err ("找不到 ISO: " + $(if ($Iso) { $Iso } else { '(未配置，也没在工程包/数据盘里找到)' }))
    Write-Info '把 ISO 放到工程包目录或数据盘下，或改 kit.config.json 的 isoPath'
    Write-Info '也可以直接指定：-Iso "D:\...\xxx.iso"'
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

# 应答文件里的映像名必须在这支 ISO 里存在，否则装到一半会中断
if (Test-Admin) {
    Write-Info "正在核对 ISO 映像名（挂载约 5 秒）..."
    $isoInfo = Get-IsoImageNames -IsoPath $Iso
    if ($isoInfo.Ok) {
        Write-Info ("映像    : " + ($isoInfo.Names -join ' | '))
        $raw = Get-Content -LiteralPath $ansPath -Raw -Encoding UTF8
        $m = [regex]::Match($raw, '(?s)<ImageInstall>.*?</ImageInstall>')
        if ($m.Success) {
            $vm = [regex]::Match($m.Value, '<Value>([^<]*)</Value>')
            if ($vm.Success) {
                $want = $vm.Groups[1].Value.Trim()
                if ($isoInfo.Names -notcontains $want) {
                    Write-Err ("应答文件要装的映像 '{0}' 不在这支 ISO 里。" -f $want)
                    Write-Info ("这支 ISO 只有：" + ($isoInfo.Names -join ' / '))
                    Stop-KitLog; exit 1
                }
                Write-Ok ("映像名匹配: " + $want)
            }
        }
    } else {
        Write-Warn ("没能解析 ISO 映像名（{0}），继续，但装的时候留意版本选择页" -f $isoInfo.Error)
    }
}

# ================================================================= 1 选 U 盘
Write-Step "1. 选择 U 盘"

$usb = @(Get-UsbDisks)
if ($usb.Count -eq 0) {
    Write-Err "没检测到 U 盘。插上 U 盘（8GB 以上）再跑。"
    Stop-KitLog; exit 1
}

foreach ($u in $usb) {
    Write-Info ("  [{0}] 磁盘{0}  {1}  {2}  盘符 {3}  卷标 {4}" -f $u.Number, $u.Friendly, (Format-Human $u.SizeBytes), `
            $(if ($u.DriveLetter) { $u.DriveLetter } else { '无' }), $u.Label)
}

$target = $null
if ($DriveLetter) {
    $target = $usb | Where-Object { $_.DriveLetter -eq $DriveLetter.TrimEnd(':').ToUpper() } | Select-Object -First 1
    if (-not $target) {
        Write-Err ("盘符 {0}: 不是一个 U 盘。当前 U 盘盘符：{1}" -f $DriveLetter, (($usb | ForEach-Object { $_.DriveLetter }) -join ','))
        Stop-KitLog; exit 1
    }
} elseif ($usb.Count -eq 1) {
    $target = $usb[0]
    Write-Info ("只有一个 U 盘，自动选中：磁盘{0} {1}" -f $target.Number, $target.Friendly)
} else {
    Write-Err "插了不止一个 U 盘，请用 -DriveLetter 指定，免得写错盘。"
    foreach ($u in $usb) { Write-Info ("    -DriveLetter " + $u.DriveLetter) }
    Stop-KitLog; exit 1
}

if ($target.SizeBytes -lt 8GB) {
    Write-Err ("U 盘只有 {0}，装不下这支 {1} 的 ISO（建议 16GB 以上）" -f (Format-Human $target.SizeBytes), (Format-Human $isoItem.Length))
    Stop-KitLog; exit 1
}
if (-not $target.DriveLetter) {
    Write-Err "这个 U 盘没有盘符（可能全被占用或未格式化）。先用磁盘管理给它分一个盘符。"
    Stop-KitLog; exit 1
}

$usbRoot = $target.DriveLetter + ':\'
Write-Ok ("目标 U 盘: {0}:  {1}  {2}" -f $target.DriveLetter, $target.Friendly, (Format-Human $target.SizeBytes))

$used = 0
try { $used = (Get-Volume -DriveLetter $target.DriveLetter).SizeRemaining } catch { }
if ($used -gt 0 -and $used -lt ($isoItem.Length + 500MB)) {
    Write-Err ("U 盘可用空间只有 {0}，不够放 ISO（已用掉太多）" -f (Format-Human $used))
    Stop-KitLog; exit 1
}

# ================================================================= 2 Ventoy
Write-Step "2. Ventoy 检查"

function Test-VentoyInstalled {
    param([string]$Root)
    if (Test-Path -LiteralPath (Join-Path $Root 'ventoy\ventoy.json')) { return $true }
    if ((Test-Path -LiteralPath (Join-Path $Root 'ventoy')) -and
        (Test-Path -LiteralPath (Join-Path $Root 'EFI\BOOT\BOOTX64.EFI'))) { return $true }
    return $false
}

$ventoyOk = Test-VentoyInstalled -Root $usbRoot
if ($ventoyOk) {
    Write-Ok "U 盘已经装好 Ventoy，不会格式化"
} else {
    Write-Warn "U 盘还没装 Ventoy"
}

function Find-VentoyExe {
    $cands = @(
        (Join-Path $script:KitRoot 'tools\Ventoy\Ventoy2Disk.exe'),
        (Join-Path $script:KitRoot 'tools\ventoy\Ventoy2Disk.exe')
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    if ($DataRoot -and (Test-Path -LiteralPath $DataRoot)) {
        $found = Get-ChildItem -LiteralPath $DataRoot -Recurse -Filter 'Ventoy2Disk.exe' -ErrorAction SilentlyContinue -Depth 3 |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-VentoyPackage {
    param([switch]$AllowDownload)
    $exe = Find-VentoyExe
    if ($exe) { return $exe }
    if (-not $AllowDownload) { return $null }

    Write-Info "本机没有 Ventoy，正在从 GitHub 下载（约 70 MB）..."
    $toolsDir = Join-Path $script:KitRoot 'tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

    try {
        $api = 'https://api.github.com/repos/ventoy/Ventoy/releases/latest'
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'reinstall-kit' } -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -like 'ventoy-*-windows.zip' } | Select-Object -First 1
        if (-not $asset) { throw '这个 release 里没有 windows.zip' }
        Write-Info ("版本: {0}" -f $rel.tag_name)

        $zip = Join-Path $toolsDir 'ventoy-windows.zip'
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'reinstall-kit')
        $wc.DownloadFile($asset.browser_download_url, $zip)
        $wc.Dispose()
        Write-Ok ("下载完成: " + (Format-Human (Get-Item -LiteralPath $zip).Length))

        $dest = Join-Path $toolsDir 'Ventoy'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $toolsDir -Force
        $inner = Get-ChildItem -LiteralPath $toolsDir -Directory | Where-Object { $_.Name -like 'ventoy-*' } | Select-Object -First 1
        if ($inner) { Move-Item -LiteralPath $inner.FullName -Destination $dest -Force }
        return (Find-VentoyExe)
    }
    catch {
        Write-Err ("自动下载 Ventoy 失败: " + $_.Exception.Message)
        Write-Info "手动办法：浏览器打开 https://www.ventoy.net/cn/download.html"
        Write-Info ("          下载 windows.zip，解压到 " + (Join-Path $script:KitRoot 'tools\Ventoy'))
        return $null
    }
}

if (-not $ventoyOk) {
    $vExe = Install-VentoyPackage -AllowDownload:(-not $NoDownload)
    if (-not $vExe) {
        Write-Err "没有 Ventoy 可执行文件，无法继续。"
        Stop-KitLog; exit 1
    }
    Write-Info ("Ventoy 程序: " + $vExe)

    Write-Danger ("接下来会把 U 盘（{0}: {1}）整只清空并装成 Ventoy 启动盘" -f $target.DriveLetter, (Format-Human $target.SizeBytes))
    Write-Host ""
    Write-Host "  这会删除 U 盘上的所有文件，且不可恢复。" -ForegroundColor Yellow
    Write-Host "  确认盘符没有选错：$($target.DriveLetter):  卷标 '$($target.Label)'" -ForegroundColor Yellow
    Write-Host ""

    if (-not (Read-YesNo "确定要格式化这只 U 盘吗" $false)) {
        Write-Warn "已取消。"
        Stop-KitLog; exit 1
    }
    if (-not (Read-ConfirmText ("再确认一次：输入盘符大写字母（如 " + $target.DriveLetter + "）") $target.DriveLetter)) {
        Write-Warn "输入不匹配，已取消。"
        Stop-KitLog; exit 1
    }

    if ($DryRun) {
        Write-Info "[演练] 会执行：Ventoy2Disk.exe VTOYCLI /I /PhyDrive:$($target.Number)"
    } else {
        if (-not (Wait-Countdown -Seconds 10 -Message "开始安装 Ventoy")) {
            Stop-KitLog; exit 1
        }

        Write-Info "正在安装 Ventoy（CLI 模式，最多等 5 分钟）..."
        $vArgs = @('VTOYCLI', '/I', "/PhyDrive:$($target.Number)")
        $p = Start-Process -FilePath $vExe -ArgumentList $vArgs -PassThru -ErrorAction Stop
        $done = $p.WaitForExit(300000)
        if (-not $done) {
            try { $p.Kill() } catch { }
            Write-Warn "CLI 模式超时，改用图形界面安装。"
            Write-Host ""
            Write-Host "  请在弹出的 Ventoy 窗口里：" -ForegroundColor Yellow
            Write-Host "    1) 确认 Device 是 $($target.DriveLetter): $($target.Friendly)" -ForegroundColor Yellow
            Write-Host "    2) 点 Install → 两次 OK" -ForegroundColor Yellow
            Write-Host "    3) 装完关掉窗口，脚本会自动继续" -ForegroundColor Yellow
            Write-Host ""
            $g = Start-Process -FilePath $vExe -PassThru -ErrorAction Stop
            $null = $g.WaitForExit(600000)
        } else {
            Write-Info ("Ventoy CLI 退出码: " + $p.ExitCode)
        }

        Start-Sleep -Seconds 3
        $ventoyOk = Test-VentoyInstalled -Root $usbRoot
        if (-not $ventoyOk) {
            # 盘符可能在安装后变化，重新枚举
            $again = @(Get-UsbDisks) | Where-Object { $_.Number -eq $target.Number } | Select-Object -First 1
            if ($again -and $again.DriveLetter) {
                $target = $again
                $usbRoot = $target.DriveLetter + ':\'
                $ventoyOk = Test-VentoyInstalled -Root $usbRoot
            }
        }
        if (-not $ventoyOk) {
            Write-Err "装完还是没检测到 Ventoy 结构。请打开 Ventoy 窗口确认是否真的安装成功。"
            Stop-KitLog; exit 1
        }
        Write-Ok "Ventoy 安装成功"
    }
}

# ================================================================= 3 拷 ISO
Write-Step "3. 拷贝 ISO"

$isoName = Split-Path $Iso -Leaf
$isoDest = Join-Path $usbRoot $isoName
$needCopy = $true
if (Test-Path -LiteralPath $isoDest) {
    $exist = Get-Item -LiteralPath $isoDest
    if ($exist.Length -eq $isoItem.Length) {
        Write-Ok ("U 盘上已有同名同大小的 ISO，跳过拷贝")
        $needCopy = $false
    } else {
        Write-Warn ("U 盘上有同名 ISO 但大小不同（{0}），将重新拷贝" -f (Format-Human $exist.Length))
    }
}

if ($DryRun) {
    if ($needCopy) { Write-Info ("[演练] 会拷贝 {0} -> {1}" -f $Iso, $isoDest) }
} elseif ($needCopy) {
    if (Test-Path -LiteralPath $isoDest) { Remove-Item -LiteralPath $isoDest -Force }

    Write-Info ("写入 {0} ..." -f (Format-Human $isoItem.Length))
    $in = [System.IO.File]::OpenRead($Iso)
    $out = [System.IO.File]::Create($isoDest)
    $buf = New-Object byte[] (4MB)
    $total = $in.Length
    $doneAll = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $doneAll += $n
            if ($sw.ElapsedMilliseconds -ge 700) {
                $pct = [Math]::Round($doneAll * 100.0 / $total, 1)
                $mbs = ($doneAll / 1MB) / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                Write-Host ("`r    {0,5:N1}%   {1} / {2}   {3:N0} MB/s   " -f $pct, (Format-Human $doneAll), (Format-Human $total), $mbs) -NoNewline -ForegroundColor Gray
                $sw.Restart()
            }
        }
        Write-Host ""
    }
    finally {
        $in.Dispose(); $out.Dispose()
    }
    $wrote = (Get-Item -LiteralPath $isoDest).Length
    if ($wrote -ne $isoItem.Length) {
        Write-Err ("写入不完整：{0} / {1}" -f $wrote, $isoItem.Length)
        Stop-KitLog; exit 1
    }
    Write-Ok ("ISO 写入完成 " + (Format-Human $wrote))
}

# ================================================================= 4 应答文件
Write-Step "4. 放置应答文件"

$ansDest = Join-Path $usbRoot 'autounattend.xml'
# 模板里的 __USER__ / __COMPUTERNAME__ / __KITNAME__ 按本机配置渲染，模板本身不含身份信息
function Render-AnswerText {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $kitName = Split-Path -Leaf $script:KitRoot
    return $text.Replace('__USER__', $LocalUserName).Replace('__COMPUTERNAME__', $LocalComputerName).Replace('__KITNAME__', $kitName)
}
$ansText = Render-AnswerText $ansPath
$generatedPath = Join-Path $script:KitRoot 'autounattend.generated.xml'

if ((Test-Path -LiteralPath $ansDest) -and -not $DryRun) {
    $oldText = Get-Content -LiteralPath $ansDest -Raw -Encoding UTF8
    if ($oldText -eq $ansText) {
        Write-Ok "U 盘根目录的 autounattend.xml 已经是最新的，跳过"
    } else {
        Write-Warn "U 盘根目录已有一个不同的 autounattend.xml，将覆盖（旧文件备份为 .bak）"
        Copy-Item -LiteralPath $ansDest -Destination ($ansDest + '.bak') -Force
    }
}

if ($DryRun) {
    Write-Info ("[演练] 会按本机配置渲染 {0} -> {1}" -f $ansPath, $ansDest)
} else {
    [IO.File]::WriteAllText($generatedPath, $ansText, (New-Object Text.UTF8Encoding($true)))
    Write-Info ("渲染结果已留存: " + $generatedPath)
    [IO.File]::WriteAllText($ansDest, $ansText, (New-Object Text.UTF8Encoding($true)))
    if (-not (Test-Path -LiteralPath $ansDest)) {
        Write-Err "应答文件写入失败"
        Stop-KitLog; exit 1
    }
    Write-Ok ("autounattend.xml 已放到 U 盘根目录（来源: {0}）" -f $AnswerFile)

    # 备用：自动分区万一因磁盘号错位报错，把它改名成 autounattend.xml 就能重来（只点分区，其余仍全自动）
    $spare = Join-Path $script:KitRoot 'autounattend-手动分区-社区重制版.xml'
    if (Test-Path -LiteralPath $spare) {
        $spareDest = Join-Path $usbRoot '备选-手动分区.xml'
        $spareText = Render-AnswerText $spare
        [IO.File]::WriteAllText($spareDest, $spareText, (New-Object Text.UTF8Encoding($true)))
        Write-Info "备用应答文件已放: 备选-手动分区.xml（自动分区失败时改名为 autounattend.xml 再用）"
    }
}

# ================================================================= 5 说明书
Write-Step "5. 生成 U 盘说明书"

$readme = @"
================================================================
 Windows 10 安装 U 盘 —— 使用说明
================================================================

U 盘内容：
  $isoName
  autounattend.xml     （来自 $AnswerFile）

一、开机进安装程序
  1. 关机，插这只 U 盘
  2. 开机后连续按 F12，直到出现启动菜单
  3. 选 "UEFI: <你的U盘名>"，回车

二、分区这一步（唯一需要手动的地方）
  · 用「卷标 + 容量」确认哪块是系统盘（不要只看盘符，PE 里盘符可能错位）
  · 选中系统盘的既有系统分区 -> 点【格式化】-> 下一步
  · 不要删除任何分区，不要点【新建】
  · 不要碰数据盘分区（通常是容量最大、卷标为数据盘的那块）

三、装的过程中
  · 全程不需要输入任何东西，会自动建账户（用户名取自 kit.config.json，空密码）
  · 大约 10~15 分钟，中间会自动重启

四、装完第一次进桌面
  · 拔掉 U 盘
  · 确认数据盘盘符与 kit.config.json 的 dataRoot 一致（不一致就去磁盘管理改回来）
  · 双击 $($script:KitRoot)\开始.cmd -> 选 6（重建链接 + 装软件）
  · 完了再选 7（收尾）

五、如果卡住
  · 卡在"让我们为你连接到网络"：Shift+F10 -> 输入 oobe\bypassnro -> 回车
  · 提示"找不到映像"：应答文件和 ISO 不匹配，重做 U 盘

生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

if ($DryRun) {
    Write-Info "[演练] 会写安装说明.txt"
} else {
    $txt = Join-Path $usbRoot '安装说明.txt'
    [System.IO.File]::WriteAllText($txt, $readme, [System.Text.Encoding]::GetEncoding(936))
    Write-Ok "安装说明.txt 已写入"
}

# ================================================================= 6 收尾
Write-Step "6. 结果"

if ($DryRun) {
    Write-Host ""
    Write-Ok "演练结束，什么都没写。去掉 -DryRun 才真正执行。"
    Stop-KitLog
    exit 0
}

Write-Info ("U 盘根目录: " + $usbRoot)
$listing = Get-ChildItem -LiteralPath $usbRoot -ErrorAction SilentlyContinue |
           Where-Object { -not $_.PSIsContainer } | Select-Object -First 12
foreach ($f in $listing) { Write-Info ("  {0,-40} {1}" -f $f.Name, (Format-Human $f.Length)) }

Write-Host ""
Write-Ok "U 盘做好了。"
Write-Host ""
Write-Host "  下一步：菜单 6「重启并进入 U 盘安装」" -ForegroundColor Cyan
Write-Host "  记得：装之前先确认 D 盘数据盘的状态（拔线 or 手动分区）" -ForegroundColor Yellow
Write-Host ""

Stop-KitLog
exit 0
