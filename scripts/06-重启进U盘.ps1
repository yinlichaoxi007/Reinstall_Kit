#requires -Version 5.1
<#
    重启并进入 U 盘安装
    ============================================================
    做三件事：再确认一次 U 盘就绪 -> 显示装机要点 -> 60 秒倒计时重启。
    倒计时期间按任意键 = 取消（会执行 shutdown /a）。

    用法：
        开始.cmd  →  5
        或： powershell -ExecutionPolicy Bypass -File 06-重启进U盘.ps1
            powershell -ExecutionPolicy Bypass -File 06-重启进U盘.ps1 -Seconds 120
#>
[CmdletBinding()]
param(
    [int]$Seconds = 60,
    [switch]$WhatIfOnly
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'reboot-to-usb' | Out-Null
Write-Head "重启进入 U 盘安装"

if (-not (Assert-Admin)) { Stop-KitLog; exit 2 }

# ================================================================= 1 检查 U 盘
Write-Step "1. 检查 U 盘就绪"

$usb = @(Get-UsbDisks)
if ($usb.Count -eq 0) {
    Write-Err "没有检测到 U 盘。先插上做好的安装 U 盘。"
    Stop-KitLog; exit 1
}

$ready = $null
foreach ($u in $usb) {
    if (-not $u.DriveLetter) { continue }
    $root = $u.DriveLetter + ':\'
    $hasAns = Test-Path -LiteralPath (Join-Path $root 'autounattend.xml')
    $hasIso = @(Get-ChildItem -LiteralPath $root -Filter '*.iso' -File -ErrorAction SilentlyContinue).Count -gt 0
    $isVentoy = Test-Path -LiteralPath (Join-Path $root 'ventoy')
    $mark = ''
    if ($hasAns -and $hasIso) { $mark = '  <- 可用来装机'; if (-not $ready) { $ready = $u } }
    Write-Info ("  {0}:  {1}  {2}  ISO:{3}  应答文件:{4}  Ventoy:{5}{6}" -f `
            $u.DriveLetter, $u.Friendly, (Format-Human $u.SizeBytes), `
            $(if ($hasIso) { '有' } else { '无' }), `
            $(if ($hasAns) { '有' } else { '无' }), `
            $(if ($isVentoy) { '是' } else { '否' }), $mark)
}

if (-not $ready) {
    Write-Err "没有找到「既有 ISO 又有 autounattend.xml」的 U 盘。先跑菜单 4 做盘。"
    Stop-KitLog; exit 1
}
Write-Ok ("将从这个 U 盘启动: {0}: {1}" -f $ready.DriveLetter, $ready.Friendly)

# ================================================================= 2 装机要点
Write-Step "2. 开机的动作（看完再确认）"

Write-Host ""
Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
Write-Host "  │ 1. 听到 Dell logo 后，连续按 F12（一秒一下，别按住）    │" -ForegroundColor Gray
Write-Host "  │ 2. 启动菜单里选  UEFI: <你的U盘名>                      │" -ForegroundColor Gray
Write-Host "  │ 3. 进入安装界面后走「自定义：仅安装 Windows」           │" -ForegroundColor Gray
Write-Host "  │ 4. 分区页：选中系统盘的原系统分区 → 格式化 → 下一步│" -ForegroundColor Gray
Write-Host "  │    不要删分区、不要点新建、不要碰数据盘      │" -ForegroundColor Gray
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  如果你想拔掉 D 盘 SATA 线（最保险），现在就该关机操作。" -ForegroundColor Yellow
Write-Host "  如果不拔线，分区页务必只点「格式化」，绝对不要「删除」。" -ForegroundColor Yellow
Write-Host ""

$fw = ''
try { $fw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop).PEFirmwareType } catch { }
if ($fw -eq 2) { Write-Ok "当前固件: UEFI（与 U 盘的 UEFI 启动一致）" }
elseif ($fw -eq 1) { Write-Warn "当前固件报告为 Legacy BIOS —— U 盘要用 UEFI 方式启动，进 BIOS 确认一下" }

# ================================================================= 3 确认
Write-Step "3. 确认"

if (-not (Read-YesNo "确认现在重启进入安装程序（未保存的工作会丢）" $false)) {
    Write-Warn "已取消，没有重启。"
    Stop-KitLog; exit 1
}
if (-not (Read-ConfirmText "再确认：输入 RESTART 开始倒计时" 'RESTART')) {
    Write-Warn "输入不匹配，已取消。"
    Stop-KitLog; exit 1
}

if ($WhatIfOnly) {
    Write-Info ("[演练] 会执行 shutdown /r /t " + $Seconds)
    Stop-KitLog; exit 0
}

# ================================================================= 4 倒计时重启
Write-Step "4. 重启"

$msg = 'Reinstall Kit: 重启进入 U 盘安装'
& shutdown /r /t $Seconds /c $msg 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "调用 shutdown 失败（退出码 $LASTEXITCODE）。手动重启也一样，记得按 F12。"
    Stop-KitLog; exit 1
}

Write-Info ("已排定 {0} 秒后重启。倒计时期间按任意键取消。" -f $Seconds)
$cancelled = $false
for ($s = $Seconds; $s -gt 0; $s--) {
    Write-Host ("`r  {0,3} 秒后重启 ... 按任意键取消   " -f $s) -NoNewline -ForegroundColor Yellow
    try {
        if ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
            $cancelled = $true
            break
        }
    } catch { }
    Start-Sleep -Milliseconds 1000
}
Write-Host ""

if ($cancelled) {
    & shutdown /a 2>&1 | Out-Null
    Write-Warn "已取消重启。"
    Stop-KitLog; exit 1
}

Write-Ok "重启已开始。开机连续按 F12 选 UEFI 启动。"
Stop-KitLog
exit 0
