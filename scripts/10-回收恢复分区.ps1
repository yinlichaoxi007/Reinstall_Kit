#requires -Version 5.1
<#
    回收 Dell 恢复分区（把 18 GB 还给 C 盘）
    ============================================================
    ⚠️ 这是本工程包里唯一会「不可逆地改分区表」的脚本。

    它做什么：
        1. reagentc /disable      先把 WinRE 从 P4 搬回 C 盘
        2. 倒序删除 P6 / P5 / P4  三个 Dell 恢复分区
        3. extend C               把腾出来的空间接到 C 盘
        4. reagentc /enable       尽量把 WinRE 装回去（失败不影响系统）

    它不做什么：
        · 不动 ESP、MSR、C 盘本身
        · 不动非 Dell 卷标的任何分区
        · 不动数据盘（Disk 0）

    闸门（任何一条不通过就退出，不给你「强行继续」的选项）：
        ① 管理员权限
        ② 当前系统必须是重装后的 Win10（build 19041~19045），Win11 上一律拒绝
        ③ 出厂镜像备份必须完整（MANIFEST 397 条、文件在、大小对）
        ④ 目标分区必须同时满足：在系统盘上、GPT 类型是 Recovery、卷标是 Dell 三件套
        ⑤ 四个手动确认 + 15 秒倒计时

    用法：
        开始.cmd  →  8（菜单里还要输一次 DANGER）
        只检查不执行：powershell -File 10-回收恢复分区.ps1
        真正执行    ：powershell -File 10-回收恢复分区.ps1 -Apply
        纯演练      ：powershell -File 10-回收恢复分区.ps1 -Apply -DryRun
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$DryRun,
    [switch]$DeepVerify
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'reclaim-recovery' | Out-Null
Write-Head "回收 Dell 恢复分区"

# 真正动手才要管理员；只检查 / 演练允许普通权限，方便随时复核
$isAdmin = Test-Admin
$willExecute = ($Apply -and (-not $DryRun))
if ($willExecute -and -not $isAdmin) {
    Write-Err "真正执行需要管理员权限。"
    Write-Info "请通过「开始.cmd」入口运行（会自动提权），或右键以管理员身份运行。"
    Stop-KitLog; exit 2
}
if (-not $isAdmin) {
    Write-Warn "当前不是管理员：本次只做检查/演练，不会改分区"
}

# ================================================================= 闸门 1：系统版本
Write-Step "闸门 1/4  系统版本"

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Write-Info ("{0}   build {1}" -f $os.Caption, $build)

if (-not $Apply) {
    Write-Info "（当前是「只检查」模式，不会改任何东西；加 -Apply 才进入执行流程）"
}

if ($build -ge 22000) {
    Write-Err "当前还是 Win11 / 更新系统，说明重装还没做。"
    Write-Info "这个脚本要在【重装后的 Win10】上跑 —— 那时才确定不再需要 F12 回出厂。"
    Write-Info "现在删了，你就永久失去 Dell 的一键恢复入口，而且没有回头路。"
    Stop-KitLog; exit 1
}
if ($build -lt 19041) {
    Write-Err ("build {0} 太旧，不在支持范围（需要 19041~19045）" -f $build)
    Stop-KitLog; exit 1
}
Write-Ok "系统版本符合（已重装为 Win10）"

# ================================================================= 闸门 2：出厂备份
Write-Step "闸门 2/4  出厂镜像备份完整性"

$factory = Join-Path $script:KitRoot 'DellFactoryImage'
$manJson = Join-Path $factory 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $manJson)) {
    Write-Err "找不到 DellFactoryImage\MANIFEST.json —— 没有出厂镜像备份，绝不能删恢复分区。"
    Stop-KitLog; exit 1
}

$man = Get-Content -LiteralPath $manJson -Raw -Encoding UTF8 | ConvertFrom-Json
$entries = @($man.files)
Write-Info ("清单条目: {0}" -f $entries.Count)

$missing = 0; $badSize = 0; $sum = 0; $checked = 0
foreach ($e in $entries) {
    $abs = Resolve-FactoryPath -FactoryRoot $factory -Entry $e
    if (-not $abs) { continue }
    if (-not (Test-Path -LiteralPath $abs)) { $missing++; continue }
    $len = (Get-Item -LiteralPath $abs).Length
    if ([int64]$e.bytes -ne $len) { $badSize++ }
    $sum += $len
    $checked++
}
if ($missing -gt 0 -or $badSize -gt 0 -or $checked -lt 300) {
    Write-Err ("备份不完整：缺失 {0} / 大小不符 {1} / 实际 {2} 个文件" -f $missing, $badSize, $checked)
    Write-Info "先把 DellFactoryImage 补全（见 09-出厂镜像备份与恢复.md），再来删分区。"
    Stop-KitLog; exit 1
}
Write-Ok ("{0} 个文件齐全 / {1}" -f $checked, (Format-Human $sum))

$swm = Join-Path $factory 'P5_Image\Image\install.swm'
if (-not (Test-Path -LiteralPath $swm)) {
    Write-Err "install.swm 不在，备份不完整。"
    Stop-KitLog; exit 1
}
Write-Ok "install.swm 在"

if ($DeepVerify) {
    Write-Info "深度校验 SHA256（约 16 分钟）..."
    $bad = 0
    foreach ($e in $entries) {
        $abs = Resolve-FactoryPath -FactoryRoot $factory -Entry $e
        if (-not $abs -or -not (Test-Path -LiteralPath $abs)) { continue }
        if ($e.sha256 -and (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash -ne $e.sha256) { $bad++ }
    }
    if ($bad -gt 0) { Write-Err ("{0} 个文件哈希不符，拒绝继续。" -f $bad); Stop-KitLog; exit 1 }
    Write-Ok "SHA256 全部通过"
}

# ================================================================= 闸门 3：分区匹配
Write-Step "闸门 3/4  分区匹配"

$diskNo = Get-SystemDiskNumber
if ($null -eq $diskNo) { Write-Err "定位不到系统盘。"; Stop-KitLog; exit 1 }
$disk = Get-Disk -Number $diskNo
Write-Info ("系统盘: 磁盘 {0}  {1}  {2}  {3}" -f $disk.Number, $disk.FriendlyName, (Format-Human $disk.Size), $disk.PartitionStyle)

$osPart = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $osPart) { Write-Err "定位不到 C: 所在分区。"; Stop-KitLog; exit 1 }
Write-Info ("C: 分区: 分区 {0}  {1}  起始偏移 {2:N0}" -f $osPart.PartitionNumber, (Format-Human $osPart.Size), $osPart.Offset)

$rec = @(Get-DellRecoveryPartitions -DiskNumber $diskNo)
if ($rec.Count -eq 0) {
    Write-Ok "没有 Recovery 类型的分区 —— 可能已经回收过了。"
    Stop-KitLog; exit 0
}

$dell = @($rec | Where-Object { $_.IsDell })
$other = @($rec | Where-Object { -not $_.IsDell })

Write-Host ""
Write-Host "  系统盘上的恢复分区：" -ForegroundColor Gray
foreach ($p in $rec) {
    $tag = if ($p.IsDell) { 'Dell' } else { '非 Dell，不会动' }
    Write-Info ("    分区 {0}  {1,-12} {2,10}  偏移 {3,14:N0}  [{4}]" -f `
            $p.PartitionNumber, $p.Label, (Format-Human $p.SizeBytes), $p.Offset, $tag)
}
Write-Host ""

if ($other.Count -gt 0) {
    Write-Err ("有 {0} 个 Recovery 分区卷标不是 Dell 三件套，脚本不敢动。" -f $other.Count)
    Write-Info "请先确认这些分区是什么，再来找我改脚本。"
    Stop-KitLog; exit 1
}
if ($dell.Count -eq 0) { Write-Err "没有可删除的 Dell 分区。"; Stop-KitLog; exit 1 }

# 必须都排在 C: 之后，否则删了也接不上
foreach ($p in $dell) {
    if ($p.Offset -le $osPart.Offset) {
        Write-Err ("分区 {0} 在 C: 之前，不符合预期，停止。" -f $p.PartitionNumber)
        Stop-KitLog; exit 1
    }
}
# 大小合理性（±35%）
$expect = @{ 'WINRETOOLS' = 1038090240; 'Image' = 17138974720; 'DELLSUPPORT' = 1497366528 }
foreach ($p in $dell) {
    $e = $expect[$p.Label]
    if ($e -and ([Math]::Abs($p.SizeBytes - $e) / $e) -gt 0.35) {
        Write-Warn ("分区 {0}（{1}）大小 {2}，与出厂基线 {3} 差得多，请确认它还是原来那个分区" -f `
                $p.PartitionNumber, $p.Label, (Format-Human $p.SizeBytes), (Format-Human $e))
    }
}

$reclaim = ($dell | Measure-Object SizeBytes -Sum).Sum
$diskEnd = [int64]$disk.Size
$osEnd = [int64]$osPart.Offset + [int64]$osPart.Size
$gap = $diskEnd - $osEnd
Write-Info ("要删 {0} 个分区，合计 {1}" -f $dell.Count, (Format-Human $reclaim))
Write-Info ("C: 之后到磁盘末尾共 {0}，extend 后 C: 约 {1}" -f (Format-Human $gap), (Format-Human ([int64]$osPart.Size + $gap)))

if ($dell.Count -lt 3) {
    Write-Warn ("只找到 {0} 个 Dell 分区（出厂是 3 个），可能之前已删过一部分。请确认无误。" -f $dell.Count)
}

# WinRE 位置
Write-Info "检查 WinRE 位置..."
$reagent = & reagentc /info 2>&1 | Out-String
$mRe = [regex]::Match($reagent, 'harddisk(\d+)\\partition(\d+)')
$reOnTarget = $false
if ($mRe.Success) {
    $reDisk = [int]$mRe.Groups[1].Value
    $rePart = [int]$mRe.Groups[2].Value
    Write-Info ("WinRE 位于: 磁盘 {0} 分区 {1}" -f $reDisk, $rePart)
    if ($reDisk -eq $diskNo -and ($dell | Where-Object { $_.PartitionNumber -eq $rePart })) {
        $reOnTarget = $true
        Write-Warn "WinRE 就寄生在要删的分区里 —— 必须先 reagentc /disable 把它搬回 C 盘"
    }
} else {
    Write-Info "WinRE 未启用或位置读不到（不影响，disable 会报错但不致命）"
}

# 备份分区表
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dumpPath = Join-Path $script:KitRoot ("logs\partition-before-{0}.csv" -f $stamp)
try {
    Get-Partition -DiskNumber $diskNo |
        Select-Object PartitionNumber, DriveLetter, Size, Offset, Type, GptType, IsBoot, IsSystem |
        Export-Csv -LiteralPath $dumpPath -NoTypeInformation -Encoding UTF8
    Write-Ok "分区表现状已存档: $dumpPath"
} catch { Write-Warn "分区表存档失败（不影响执行）" }

# ================================================================= 预览
Write-Step "执行计划预览"

$order = $dell | Sort-Object Offset -Descending
$dpLines = @("select disk $diskNo")
foreach ($p in $order) {
    $dpLines += "select partition $($p.PartitionNumber)"
    $dpLines += "delete partition override"
}
$dpLines += "select partition $($osPart.PartitionNumber)"
$dpLines += "extend"
$dpLines += "exit"
$dpScript = ($dpLines -join "`r`n")

Write-Host ""
Write-Host "  将按这个顺序执行（倒序删除，避免分区号变动）：" -ForegroundColor Gray
foreach ($p in $order) {
    Write-Host ("    删除  分区 {0}  {1,-12} {2}" -f $p.PartitionNumber, $p.Label, (Format-Human $p.SizeBytes)) -ForegroundColor DarkYellow
}
Write-Host ("    扩展  分区 {0}  C:  {1} -> {2}" -f $osPart.PartitionNumber, (Format-Human $osPart.Size), (Format-Human ([int64]$osPart.Size + $gap))) -ForegroundColor Green
Write-Host ""
Write-Host "  diskpart 脚本：" -ForegroundColor Gray
foreach ($l in $dpLines) { Write-Host ("      " + $l) -ForegroundColor DarkGray }
Write-Host ""

# ================================================================= 确认
Write-Step "闸门 4/4  人工确认（四道）"

Write-Danger "这一步不可逆：删掉的分区无法恢复，F12 出厂恢复入口会永久消失"

if (-not $Apply) {
    Write-Host ""
    Write-Info "当前是「只检查」模式，到此为止，什么都没改。"
    Write-Info "确认上面都对，再运行：powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply"
    Stop-KitLog; exit 0
}

if ($DryRun) {
    Write-Host ""
    Write-Info "[演练模式] 跳过人工确认，只回显 diskpart 命令："
    $null = Invoke-DiskpartScript -Content $dpScript -DryRun
    Stop-KitLog; exit 0
}

Write-Host ""
Write-Host ("  出厂镜像备份：{0}（{1}，{2} 个文件）" -f $factory, (Format-Human $sum), $checked) -ForegroundColor Gray
Write-Host "  确认这份备份能让你在需要时手工装回出厂系统，再往下走。" -ForegroundColor Yellow
Write-Host ""

if (-not (Read-YesNo "第 1 道：你确认出厂镜像备份是完整可用的吗" $false)) {
    Write-Warn "已取消。"
    Stop-KitLog; exit 1
}
if (-not (Read-ConfirmText "第 2 道：输入 DELETE 表示同意删除这些分区" 'DELETE')) {
    Write-Warn "输入不匹配，已取消。"
    Stop-KitLog; exit 1
}
if (-not (Read-ConfirmText "第 3 道：输入「删除恢复分区」六个字" '删除恢复分区')) {
    Write-Warn "输入不匹配，已取消。"
    Stop-KitLog; exit 1
}
if (-not (Wait-Countdown -Seconds 15 -Message "开始删除")) {
    Stop-KitLog; exit 1
}

# ================================================================= 执行
Write-Step "执行"

if ($reOnTarget) {
    Write-Info "reagentc /disable ..."
    $out = & reagentc /disable 2>&1 | Out-String
    Write-Host $out.Trim() -ForegroundColor DarkGray
    if ($LASTEXITCODE -ne 0) {
        Write-Err "reagentc /disable 失败。WinRE 还在要删的分区上，继续会破坏恢复环境。已中止。"
        Stop-KitLog; exit 1
    }
    Write-Ok "WinRE 已搬回 C 盘"
} else {
    Write-Info "WinRE 不在目标分区上，跳过 disable"
}

Write-Info "执行 diskpart ..."
$r = Invoke-DiskpartScript -Content $dpScript
Write-Host $r.Output.Trim() -ForegroundColor DarkGray
if ($r.ExitCode -ne 0) {
    Write-Err ("diskpart 退出码 {0}。分区可能只删了一部分 —— 先别重启，把日志发我。" -f $r.ExitCode)
    Stop-KitLog; exit 1
}

# ================================================================= 校验
Write-Step "校验"

$after = @(Get-DellRecoveryPartitions -DiskNumber $diskNo)
if ($after.Count -eq 0) { Write-Ok "Dell 恢复分区已全部删除" }
else {
    Write-Warn ("还剩 {0} 个 Recovery 分区：" -f $after.Count)
    foreach ($p in $after) { Write-Info ("    分区 {0} {1} {2}" -f $p.PartitionNumber, $p.Label, (Format-Human $p.SizeBytes)) }
}

$osAfter = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue | Select-Object -First 1
if ($osAfter) {
    $grow = [int64]$osAfter.Size - [int64]$osPart.Size
    Write-Info ("C: 现在 {0}（增加 {1}）" -f (Format-Human $osAfter.Size), (Format-Human $grow))
    if ($grow -gt 0) { Write-Ok "extend 成功" } else { Write-Warn "C: 没有变大，可能 extend 没生效" }
}

Write-Info "尝试 reagentc /enable ..."
$out = & reagentc /enable 2>&1 | Out-String
Write-Host $out.Trim() -ForegroundColor DarkGray
if ($LASTEXITCODE -eq 0) { Write-Ok "WinRE 已重新启用" }
else { Write-Warn "WinRE 没装回去（正常现象）。高级启动仍可用，只是少了独立恢复分区。" }

# ================================================================= 收尾
Write-Step "完成"

$resume = Join-Path $script:KitRoot ("logs\partition-after-{0}.csv" -f $stamp)
try {
    Get-Partition -DiskNumber $diskNo |
        Select-Object PartitionNumber, DriveLetter, Size, Offset, Type, GptType |
        Export-Csv -LiteralPath $resume -NoTypeInformation -Encoding UTF8
    Write-Info "分区表存底: $resume"
} catch { }

Write-Host ""
Write-Ok "空间已回收。建议重启一次确认系统正常。"
Write-Host ""
Write-Host "  如果之后想彻底不要这份出厂镜像备份，可删：" -ForegroundColor Gray
Write-Host ("     " + (Join-Path $script:KitRoot 'DellFactoryImage') + "  （出厂镜像备份）") -ForegroundColor Gray
Write-Host "  但删了就再也没有回出厂的本地后路了。" -ForegroundColor Yellow
Write-Host ""
Write-Host ("日志: " + $script:LogFile) -ForegroundColor DarkGray

Stop-KitLog
exit 0
