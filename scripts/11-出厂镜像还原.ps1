#requires -Version 5.1
<#
    从 D 盘备份还原出厂 Windows（回滚用）
    ============================================================
    为什么不在这个脚本里直接还原：
        还原要格式化 C: 并把映像写进去，这件事只能在 WinPE 里做
        （正在运行的系统不能格式化自己）。而 Windows 安装盘的 PE 里
        通常没有 PowerShell。

    所以这里做两件事：
        1. 把 D:\Reinstall_Kit\DellFactoryImage 的完整性再核一遍
        2. 在 D:\Reinstall_Kit\ 下生成一个「还原出厂系统.cmd」
           —— 你在 WinPE 的命令行里输入它的路径回车就行，不用背命令

    用法：
        开始.cmd  →  9
        或： powershell -ExecutionPolicy Bypass -File 11-出厂镜像还原.ps1
#>
[CmdletBinding()]
param(
    [switch]$DeepVerify
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'factory-restore' | Out-Null
Write-Head "出厂镜像还原（生成 WinPE 用的批处理）"

# ================================================================= 1 校验备份
Write-Step "1. 校验备份完整性"

$factory = Join-Path $script:KitRoot 'DellFactoryImage'
$manJson = Join-Path $factory 'MANIFEST.json'
$swmDir = Join-Path $factory 'P5_Image\Image'
$swm1 = Join-Path $swmDir 'install.swm'

if (-not (Test-Path -LiteralPath $manJson)) { Write-Err "MANIFEST.json 不存在，备份不完整。"; Stop-KitLog; exit 1 }
if (-not (Test-Path -LiteralPath $swm1)) { Write-Err "install.swm 不存在，备份不完整。"; Stop-KitLog; exit 1 }

$man = Get-Content -LiteralPath $manJson -Raw -Encoding UTF8 | ConvertFrom-Json
$entries = @($man.files)
$missing = 0; $badSize = 0; $checked = 0; $sum = 0
foreach ($e in $entries) {
    $abs = Resolve-FactoryPath -FactoryRoot $factory -Entry $e
    if (-not $abs) { continue }
    if (-not (Test-Path -LiteralPath $abs)) { $missing++; continue }
    $len = (Get-Item -LiteralPath $abs).Length
    if ([int64]$e.bytes -ne $len) { $badSize++ }
    $checked++; $sum += $len
}
if ($missing -gt 0 -or $badSize -gt 0) {
    Write-Err ("备份不完整：缺失 {0} / 大小不符 {1}" -f $missing, $badSize)
    Stop-KitLog; exit 1
}
Write-Ok ("{0} 个文件齐全 / {1}" -f $checked, (Format-Human $sum))

# 分卷是否齐（install.swm / install2.swm / install3.swm）
$swms = @(Get-ChildItem -LiteralPath $swmDir -Filter 'install*.swm' -File | Sort-Object Name)
Write-Info ("分卷: " + (($swms | ForEach-Object { "{0} ({1})" -f $_.Name, (Format-Human $_.Length) }) -join '  '))
if ($swms.Count -lt 2) { Write-Warn "只找到 1 个分卷，出厂镜像应该是 3 个，确认一下备份是否完整" }

$winre = Join-Path $swmDir 'winre.wim'
if (Test-Path -LiteralPath $winre) { Write-Ok ("winre.wim 在（" + (Format-Human (Get-Item $winre).Length) + "）") }
else { Write-Warn "winre.wim 不在 —— 系统能装回去，但恢复环境要另外补" }

if ($DeepVerify) {
    Write-Info "深度校验 SHA256（约 16 分钟）..."
    $bad = 0
    foreach ($e in $entries) {
        $abs = Resolve-FactoryPath -FactoryRoot $factory -Entry $e
        if (-not $abs -or -not (Test-Path -LiteralPath $abs)) { continue }
        if ($e.sha256 -and (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash -ne $e.sha256) { $bad++ }
    }
    if ($bad -gt 0) { Write-Err ("{0} 个哈希不符" -f $bad); Stop-KitLog; exit 1 }
    Write-Ok "SHA256 全部通过"
}

# ================================================================= 2 当前环境
Write-Step "2. 当前环境"

$inPe = $false
if (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') { $inPe = $true }
if ($env:SystemDrive -eq 'X:') { $inPe = $true }
if ($inPe) {
    Write-Warn "检测到当前在 WinPE 里。这个脚本是给正常系统用的，PE 里请直接跑生成的 .cmd。"
} else {
    Write-Ok "当前是正常系统 —— 生成的批处理要重启进 WinPE 后使用"
}

# ================================================================= 3 生成批处理
Write-Step "3. 生成还原批处理"

$bat = @'
@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
title 还原出厂 Windows 10 - Dell Factory Image
color 0E

echo.
echo ============================================================
echo   从 D 盘备份还原出厂 Windows 10（家庭中文版 20H2）
echo   这个操作会格式化目标系统分区，C 盘上的东西会全部丢失
echo ============================================================
echo.

rem ---------- 定位工程包（卷标 DATA，路径固定） ----------
set "KIT="
for %%D in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined KIT if exist "%%D:\Reinstall_Kit\DellFactoryImage\P5_Image\Image\install.swm" set "KIT=%%D:\Reinstall_Kit"
)
if not defined KIT (
    echo [错误] 没找到 D:\Reinstall_Kit\DellFactoryImage
    echo        先确认数据盘已接上，且在磁盘管理里盘符是 D
    pause
    exit /b 1
)
echo [1/6] 工程包: %KIT%
echo.

rem ---------- 显示磁盘 ----------
echo [2/6] 当前磁盘列表
echo ------------------------------------------------------------
(echo list disk) > "%TEMP%\dp_list.txt"
diskpart /s "%TEMP%\dp_list.txt"
echo ------------------------------------------------------------
echo   系统盘通常是容量较小的那块 SSD / NVMe
echo   不要选数据盘（通常是容量最大的那块）
echo.
set /p DISK=请输入系统盘磁盘号（只输数字）:
echo.
echo [3/6] 磁盘 %DISK% 的分区
echo ------------------------------------------------------------
(
echo select disk %DISK%
echo list partition
) > "%TEMP%\dp_list2.txt"
diskpart /s "%TEMP%\dp_list2.txt"
echo ------------------------------------------------------------
echo   主分区（OS，即原来的 C 盘）= 要还原的目标
echo   系统分区（System，FAT32，通常 100~300 MB）= ESP
echo.
set /p OSPART=请输入【主分区】编号:
set /p ESPPART=请输入【系统分区 ESP】编号:
echo.
set /p OSDRIVE=请输入给主分区临时分配的盘符（单个字母，如 W）:
echo   将把主分区挂到 %OSDRIVE%:，把 ESP 挂到 S:
echo.
echo   !!! 最后确认：磁盘 %DISK% 分区 %OSPART% 会被格式化 !!!
set /p OK1=确认请输入 RESTORE :
if /i not "%OK1%"=="RESTORE" (echo 已取消& pause & exit /b 2)
set /p OK2=再输入一次 FORMAT :
if /i not "%OK2%"=="FORMAT" (echo 已取消& pause & exit /b 2)
echo.
echo   10 秒后开始，按 Ctrl+C 可中止 ...
timeout /t 10 /nobreak >nul

echo.
echo [4/6] 分区准备
(
echo select disk %DISK%
echo select partition %OSPART%
echo format quick fs=ntfs label="OS"
echo assign letter=%OSDRIVE%
echo select partition %ESPPART%
echo assign letter=S
) > "%TEMP%\dp_prep.txt"
diskpart /s "%TEMP%\dp_prep.txt"
if errorlevel 1 (echo [错误] 分区准备失败 & pause & exit /b 3)

echo.
echo [5/6] 释放映像（约 10~20 分钟，别关窗口）
pushd "%KIT%\DellFactoryImage\P5_Image\Image"
dism /Apply-Image /ImageFile:install.swm /SWMFile:install*.swm /Index:1 /ApplyDir:%OSDRIVE%:\
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
    echo [错误] 映像释放失败，退出码 %RC%
    echo        常见原因：分卷不全、目标分区太小、数据线松动
    pause
    exit /b 4
)

echo.
echo [6/6] 重建 UEFI 引导
bcdboot %OSDRIVE%:\Windows /s S: /f UEFI
if errorlevel 1 (
    echo [警告] bcdboot 失败，系统装好了但可能起不来
    echo        进 PE 后手动执行：bcdboot %OSDRIVE%:\Windows /s S: /f UEFI
)

echo.
echo ============================================================
echo   还原完成。取出 U 盘，输入 exit 后重启。
echo   首次开机会走 OOBE，按提示建账户即可。
echo   出厂系统是 Win10 20H2（已停止支持），只当临时兜底用。
echo ============================================================
pause
endlocal
exit /b 0
'@

$batPath = Join-Path $script:KitRoot '还原出厂系统.cmd'
$batGbk = $bat -replace "`r?`n", "`r`n"
[System.IO.File]::WriteAllText($batPath, $batGbk, [System.Text.Encoding]::GetEncoding(936))
Write-Ok ("已生成: " + $batPath)

# ================================================================= 4 使用说明
Write-Step "4. 怎么用"

Write-Host ""
Write-Host "  前提：D 盘这份备份在（16.68 GB），且 D 盘是 NTFS 可读" -ForegroundColor Gray
Write-Host ""
Write-Host "  步骤：" -ForegroundColor Cyan
Write-Host "    1) 用任何 WinPE U 盘启动（微PE / 安装盘 / Ventoy 里的 PE 都行）"
Write-Host "    2) 进 PE 后打开命令行（微PE 桌面有「命令提示符」）"
Write-Host "    3) 输入： D:\Reinstall_Kit\还原出厂系统.cmd"
Write-Host "    4) 按屏幕提示输磁盘号、分区号、盘符，两次确认后开始"
Write-Host ""
Write-Host "  注意：" -ForegroundColor Yellow
Write-Host "    · 这个批处理只格式化「你指定的那一个分区」，不动 ESP、不动恢复分区"
Write-Host "    · 还原出来是 2021 年 9 月的 Win10 20H2，能用但没有更新"
Write-Host "    · 想长期用还是装 IoT LTSC（菜单 4 做的那只 U 盘）"
Write-Host ""

Stop-KitLog
exit 0
