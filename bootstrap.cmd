@echo off
setlocal
chcp 936 >nul 2>&1
title Windows 10 首次配置 - Reinstall Kit
color 0A

set "KIT=%~dp0"
if "%KIT:~-1%"=="\" set "KIT=%KIT:~0,-1%"

echo.
echo ============================================================
echo   Windows 10 首次配置向导
echo   工具包位置: %KIT%
echo ============================================================
echo.

rem ---------- 0. 管理员检查 ----------
net session >nul 2>&1
if errorlevel 1 (
    echo [错误] 请右键以管理员身份运行本脚本。
    pause
    exit /b 1
)
echo [1/6] 权限检查通过
echo.

rem ---------- 1. 数据盘检查 ----------
echo [2/6] 检查数据盘...
set "DATAROOT="
if exist "D:\migration" set "DATAROOT=D:"
if not defined DATAROOT if exist "E:\migration" set "DATAROOT=E:"
if not defined DATAROOT if exist "F:\migration" set "DATAROOT=F:"

if not defined DATAROOT (
    echo.
    echo   [严重] 找不到数据盘！在 D/E/F 盘都没有找到 migration 目录。
    echo   可能原因：D 盘的 SATA 线还没插回，或者盘符变成了别的字母。
    echo.
    echo   请先处理：
    echo     1. 关机，插回 数据盘的数据线
    echo     2. 开机后打开「磁盘管理」，把数据盘的盘符改成 D
    echo     3. 然后重新运行本脚本
    echo.
    pause
    exit /b 2
)

if /i not "%DATAROOT%"=="D:" (
    echo.
    echo   [警告] 数据盘当前是 %DATAROOT% ，但链接清单里的路径写的是 D:\migration
    echo   请到「磁盘管理」里把这块盘的盘符改回 D，否则所有链接都会指错。
    echo   改完再重新运行本脚本。
    echo.
    pause
    exit /b 3
)
echo   数据盘 OK: D:\migration
echo.

rem ---------- 2. 重建链接 ----------
echo [3/6] 重建 D 盘数据链接（37 个 junction）...
echo ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%KIT%\scripts\2-重建链接.ps1"
set "RC_LINK=%ERRORLEVEL%"
echo ------------------------------------------------------------
if "%RC_LINK%"=="0" (
    echo   [OK] 链接重建完成
) else (
    echo   [警告] 有链接重建失败，详见 %KIT%\logs\restore-links_*.log
)
echo.

rem ---------- 2.5 链接校验：启动程序前的门禁 ----------
echo [4/6] 校验链接与数据可达性...
echo   检查 37 条链接指向是否正确、Joplin 库与附件能不能真读到。
echo ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%KIT%\scripts\16-校验链接.ps1"
set "RC_VERIFY=%ERRORLEVEL%"
echo ------------------------------------------------------------
if not "%RC_VERIFY%"=="0" (
    echo.
    echo   [中止] 链接校验未通过，已停止后续安装。
    echo.
    echo   原因：链接不对就装软件，程序会把数据写到 C 盘，
    echo         重装完就找不回来了。
    echo.
    echo   处理：
    echo     1. 看上面标 FAIL 的那几条；
    echo     2. 执行 scripts\16-校验链接.ps1 -Fix 自动重建链接；
    echo     3. 修好后重跑本脚本。
    echo.
    pause
    exit /b 4
)
echo   [OK] 链接与数据校验通过，可以装软件了
echo.

rem ---------- 3. 装软件 ----------
echo [5/6] 批量安装常用软件...
echo   首批只装办公必需的 16 个包，预计 15-25 分钟。
echo   网易UU远程排第一位，装好即可远程接管，不必守在机器前。
echo ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%KIT%\scripts\3-装软件.ps1" -Manifest packages-min.json
echo ------------------------------------------------------------
echo.

rem ---------- 4. 收尾提示 ----------
echo [6/6] 收尾
echo.
echo   1) 请立刻设置登录密码（当前为空密码）：
echo        net user %USERNAME% *
echo.
echo   2) 大体积软件手动装：
echo        在本目录打开 PowerShell，执行
echo        powershell -ExecutionPolicy Bypass -File scripts\3-装软件.ps1 -Manifest packages-all.json
echo.
echo   3) 装完 Dell 驱动后重启一次。
echo   4) 个人数据从 D:\Reinstall_Kit\backup\ 里按 恢复清单.md 拷回。
echo.

if exist "%KIT%\logs" (
    echo   安装报告目录: %KIT%\logs
    start "" "%KIT%\logs"
)

echo.
echo ============================================================
echo   首次配置结束。按任意键关闭此窗口。
echo ============================================================
pause >nul
endlocal
exit /b 0
