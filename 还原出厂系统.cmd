@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
title 还原出厂 Windows 10 - Dell Factory Image
color 0E

echo.
echo ============================================================
echo   从工程包里的出厂镜像还原 Windows 10（家庭中文版 20H2）
echo   这个操作会格式化目标系统分区，C 盘上的东西会全部丢失
echo ============================================================
echo.

rem ---------- 定位工程包（在 D~Z 各盘根目录下找） ----------
set "KIT="
for %%D in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined KIT if exist "%%D:\Reinstall_Kit\DellFactoryImage\P5_Image\Image\install.swm" set "KIT=%%D:\Reinstall_Kit"
)
if not defined KIT (
    echo [错误] 没在 D~Z 各盘根目录下找到 Reinstall_Kit\DellFactoryImage
    echo        先确认数据盘已接上、盘符正常
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
echo   系统盘通常是容量较小那块 SSD / NVMe
echo   不要选容量最大那块（通常是数据盘）
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