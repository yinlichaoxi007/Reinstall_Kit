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

rem ---------- 1. 数据目录检查 ----------
echo [2/6] 检查数据目录...
set "MIGROOT="
set "MIGTMP=%TEMP%\kit_migroot.txt"
if exist "%KIT%\kit.config.json" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=ConvertFrom-Json (Get-Content -LiteralPath '%KIT%\kit.config.json' -Raw -Encoding UTF8); [IO.File]::WriteAllText('%MIGTMP%', [string]$c.migrationRoot)" >nul 2>&1
    if exist "%MIGTMP%" set /p MIGROOT=<"%MIGTMP%"
)
if exist "%MIGTMP%" del "%MIGTMP%" >nul 2>&1
if defined MIGROOT if not exist "%MIGROOT%\" set "MIGROOT="

if not defined MIGROOT (
    echo.
    echo   [严重] 没有可用的数据目录。
    echo   请检查：
    echo     1. 数据盘是否已接回、盘符是否与 kit.config.json 的 migrationRoot 一致
    echo     2. 工程包里的 kit.config.json 是否填了 migrationRoot
    echo   改好后重新运行本脚本。
    echo.
    pause
    exit /b 2
)
echo   数据目录 OK: %MIGROOT%
echo.
rem ---------- 2. 重建链接 ----------
echo [3/6] 重建数据链接（links.csv 里的 junction）...
echo ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%KIT%\scripts\重建链接.ps1"
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
echo   检查 links.csv 里的链接指向是否正确、Joplin 库与附件能不能真读到。
echo ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%KIT%\scripts\08-校验链接.ps1"
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
    echo     2. 执行 scripts\08-校验链接.ps1 -Fix 自动重建链接；
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%KIT%\scripts\装软件.ps1" -Manifest packages-min.json
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
echo        powershell -ExecutionPolicy Bypass -File scripts\装软件.ps1 -Manifest packages-all.json
echo.
echo   3) 装完 Dell 驱动后重启一次。
echo   4) 个人数据从备份目录拷回（默认 %KIT%\backup，见 kit.config.json 的 backupRoot）。
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
