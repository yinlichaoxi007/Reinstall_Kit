@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
set "EMPTY=0"
title Reinstall Kit - Windows 10 重装工程包
color 0B

set "KIT=%~dp0"
if "%KIT:~-1%"=="\" set "KIT=%KIT:~0,-1%"

rem ---------- 自动提权 ----------
net session >nul 2>&1
if errorlevel 1 (
    if defined KIT_NOELEVATE (
        echo   [测试模式] 跳过提权
    ) else (
        echo.
        echo   需要管理员权限，正在弹出授权窗口，请点「是」...
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
        exit /b
    )
)

rem ---------- 找 python ----------
set "PY="
for %%P in (python.exe) do if not defined PY if exist "%%~$PATH:P" set "PY=%%~$PATH:P"
if not defined PY if exist "%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe" set "PY=%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe"
if not defined PY for %%P in (py.exe) do if not defined PY if exist "%%~$PATH:P" set "PY=%%~$PATH:P"

set "PSRUN=powershell -NoProfile -ExecutionPolicy Bypass -File"

:menu
cls
echo.
echo ================================================================
echo    Windows 10 重装工程包
echo    工程目录: %KIT%
echo ================================================================
echo.
echo   【准备阶段 · 现在这台机器上跑】
echo     1   全流程体检（只读，先跑这个）
echo     2   备份 C 盘漏网数据
echo     3   准备 winget 离线包
echo     4   制作 Ventoy 安装盘（会清空整只 U 盘）
echo     5   拷到已有 WePE 盘（不动分区，推荐）
echo     6   重启并进入 U 盘安装
echo.
echo   【重装之后】
echo     7   重建链接 + 批量装软件
echo     8   校验链接与数据可达（装程序前先跑）
echo     9   收尾检查（链接/激活/数据恢复）
echo.
echo   【危险操作 · 需要多重确认】
echo    10  回收 Dell 恢复分区（空间还给系统盘）
echo    11  从出厂镜像还原系统（回滚）
echo.
echo   【辅助脚本 · Win11 内存维护（非重装必需）】
echo    12  内存瘦身 · 只看报告 / 执行
echo    13  explorer 句柄守护 · 看状态 / 重启
echo    14  回收已提交内存 · 演练 / 执行
echo.
echo   【维护 · 随时可跑】
echo    15  清空回收站（选盘，默认全部）
echo    16  扫描 / 记录链接（维护 links.csv）
echo.
echo     0   自检所有脚本（改了脚本之后跑）
echo     H   打开重装总手册
echo     Q   退出
echo.
set "CH="
set /p CH=请输入编号后回车:
if not defined CH (
    set /a "EMPTY+=1"
    if !EMPTY! geq 3 (
        echo.
        echo   连续空输入，退出。
        exit /b 0
    )
    goto menu
)
set "EMPTY=0"

if /i "%CH%"=="1" goto m1
if /i "%CH%"=="2" goto m2
if /i "%CH%"=="3" goto m3
if /i "%CH%"=="4" goto m4
if /i "%CH%"=="5" goto m5
if /i "%CH%"=="6" goto m6
if /i "%CH%"=="7" goto m7
if /i "%CH%"=="8" goto m8
if /i "%CH%"=="9" goto m9
if /i "%CH%"=="10" goto m10
if /i "%CH%"=="11" goto m11
if /i "%CH%"=="12" goto m12
if /i "%CH%"=="13" goto m13
if /i "%CH%"=="14" goto m14
if /i "%CH%"=="15" goto m15
if /i "%CH%"=="16" goto m16
if /i "%CH%"=="0" goto m0
if /i "%CH%"=="H" goto mh
if /i "%CH%"=="Q" exit /b 0
goto menu

rem ================================================================
:m1
cls
%PSRUN% "%KIT%\scripts\01-体检.ps1"
goto done

:m2
cls
echo.
echo  备份 C 盘漏网数据（分类由 backup.config.json 定义）：
echo    1  看计划 · 全部默认分类（不动任何文件）
echo    2  看计划 · 先选分类
echo    3  直接备份 · 全部默认分类
echo    4  直接备份 · 先选分类
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    if not defined PY (
        echo [错误] 没找到 python，无法运行备份脚本
        goto done
    )
    "%PY%" "%KIT%\scripts\02-备份.py"
    goto done
)
if "%S%"=="2" (
    if not defined PY (
        echo [错误] 没找到 python，无法运行备份脚本
        goto done
    )
    "%PY%" "%KIT%\scripts\02-备份.py" --select
    if errorlevel 3 goto m2
    goto done
)
if "%S%"=="3" (
    if not defined PY (
        echo [错误] 没找到 python，无法运行备份脚本
        goto done
    )
    echo.
    echo   开始备份，期间不要关闭窗口。完成后会显示落点目录。
    echo.
    "%PY%" "%KIT%\scripts\02-备份.py" --run
    goto done
)
if "%S%"=="4" (
    if not defined PY (
        echo [错误] 没找到 python，无法运行备份脚本
        goto done
    )
    "%PY%" "%KIT%\scripts\02-备份.py" --select --run
    if errorlevel 3 goto m2
    goto done
)
goto menu

:m3
cls
%PSRUN% "%KIT%\scripts\03-准备离线包.ps1"
goto done

:m4
cls
%PSRUN% "%KIT%\scripts\04-做U盘.ps1"
goto done

:m5
cls
%PSRUN% "%KIT%\scripts\05-拷到WePE盘.ps1"
goto done

:m6
cls
%PSRUN% "%KIT%\scripts\06-重启进U盘.ps1"
goto done

:m7
cls
call "%KIT%\bootstrap.cmd"
goto done

:m8
cls
echo   校验 links.csv 里的链接指向是否正确，以及 Joplin 库/附件能否真读到。
echo   装任何程序之前都应该先跑这个；链接不对就装，数据会写到 C 盘。
echo.
echo     1   只校验（默认）
echo     2   校验 + 发现异常时自动重建链接
echo.
set /p S=选择（直接回车=1）: 
if /i "%S%"=="2" goto m8fix
%PSRUN% "%KIT%\scripts\08-校验链接.ps1"
goto done

:m8fix
%PSRUN% "%KIT%\scripts\08-校验链接.ps1" -Fix
goto done

:m9
cls
%PSRUN% "%KIT%\scripts\09-收尾.ps1"
goto done

:m10
cls
echo.
echo ================================================================
echo    危险：回收 Dell 恢复分区
echo ================================================================
echo.
echo    这个操作会删除 NVMe 上的三个 Dell 恢复分区，把 18 GB 并回 C 盘。
echo    删除后：
echo      - F12 里的 Factory Image Restore 一键入口永久消失
echo      - 只能靠工程包里的 DellFactoryImage 手工还原
echo.
echo    脚本自己会检查：系统是不是已重装、备份是不是完整、
echo    分区是不是真的 Dell 那三个。任何一条不满足都会拒绝执行。
echo.
echo    脚本里还有四道人工确认（DELETE / 删除恢复分区 / 倒计时）。
echo.
set "DC="
set /p DC=如果你已经想清楚，输入 DANGER 继续（直接回车返回）:
if /i not "%DC%"=="DANGER" goto menu
cls
%PSRUN% "%KIT%\scripts\10-回收恢复分区.ps1" -Apply
goto done

:m11
cls
echo.
echo   这是"回滚到出厂系统"用的：会生成一个 WinPE 里运行的批处理。
echo    1  检查备份完整性并生成 还原出厂系统.cmd
echo    2  顺便做 SHA256 深度校验（16 分钟）
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\11-出厂镜像还原.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\11-出厂镜像还原.ps1" -DeepVerify
    goto done
)
goto menu

:m12
cls
echo.
echo   内存瘦身（Win11 专用，辅助脚本）：
echo    1  内存瘦身 · 只看报告（30 秒采样）
echo    2  内存瘦身 · 执行（关服务/启动项前会问你）
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\12-内存瘦身.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\12-内存瘦身.ps1" -TrimServices -TrimStartup -Apply
    goto done
)
goto menu

:m13
cls
echo.
echo   explorer 句柄守护：
echo    1  看状态
echo    2  立即重启 explorer
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\13-explorer守护.ps1" -Action Status
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\13-explorer守护.ps1" -Action Restart
    goto done
)
goto menu

:m14
cls
echo.
echo   回收已提交内存：
echo    1  演练（只报告，不动手）
echo    2  执行（含 MSBuild / Joplin 后台进程）
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\14-回收内存.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\14-回收内存.ps1" -Apply
    goto done
)
goto menu

:m15
cls
echo.
echo   清空回收站（可选全部盘或某个盘，默认全部）：
echo    1  执行（脚本内选盘，默认全部；会二次确认）
echo    2  演练（只统计，不删除）
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\15-清空回收站.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\15-清空回收站.ps1" -WhatIf
    goto done
)
goto menu

:m16
cls
echo.
echo   扫描 / 记录链接（维护 links.csv）：
echo    1  扫描并校验（只读，列出未记录的迁移链接）
echo    2  扫描后选择要记录的链接（追加进 links.csv）
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\16-扫描链接.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\16-扫描链接.ps1" -Record
    goto done
)
goto menu

:m0
cls
%PSRUN% "%KIT%\scripts\99-自检.ps1"
goto done

:mh
start "" "%KIT%\00-重装总手册.md"
goto menu

:done
echo.
echo ----------------------------------------------------------------
echo   本步骤结束。按任意键回主菜单。
echo ----------------------------------------------------------------
pause >nul
goto menu
