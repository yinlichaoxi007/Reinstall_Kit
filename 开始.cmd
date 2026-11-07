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
echo     12  拷到已有 WePE 盘（不动分区，推荐）
echo     13  备份 Joplin 笔记库（库+设置+插件，约 190 MB）
echo     14  备份 Joplin（连 4.5 GB 附件，慢一些）
echo     5   重启并进入 U 盘安装
echo.
echo   【重装之后】
echo     6   重建链接 + 批量装软件
echo     15  校验链接与数据可达（装程序前先跑）
echo     7   收尾检查（链接/激活/数据恢复）
echo.
echo   【危险操作 · 需要多重确认】
echo     8   回收 Dell 恢复分区（把 18GB 还给 C 盘）
echo     9   从出厂镜像还原系统（回滚）
echo.
echo   【辅助脚本 · Win11 内存维护（非重装必需）】
echo    20  内存瘦身 · 只看报告 / 执行
echo    21  explorer 句柄守护 · 看状态 / 重启
echo    22  回收已提交内存 · 演练 / 执行
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
if /i "%CH%"=="10" goto m20
if /i "%CH%"=="11" goto m22
if /i "%CH%"=="12" goto m12
if /i "%CH%"=="13" goto m13
if /i "%CH%"=="14" goto m14
if /i "%CH%"=="15" goto m15
if /i "%CH%"=="20" goto m20
if /i "%CH%"=="21" goto m21
if /i "%CH%"=="22" goto m22
if /i "%CH%"=="0" goto m0
if /i "%CH%"=="H" goto mh
if /i "%CH%"=="Q" exit /b 0
goto menu

rem ================================================================
:m1
cls
%PSRUN% "%KIT%\scripts\0-体检.ps1"
goto done

:m2
cls
echo.
echo  备份有两种跑法：
echo    1  先看计划（不动任何文件）
echo    2  直接开始备份（约 4.8 GB，10~30 分钟）
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    if not defined PY (
        echo [错误] 没找到 python，无法运行备份脚本
        goto done
    )
    "%PY%" "%KIT%\scripts\1-备份.py"
    goto done
)
if "%S%"=="2" (
    if not defined PY (
        echo [错误] 没找到 python，无法运行备份脚本
        goto done
    )
    echo.
    echo   开始备份，期间不要关闭窗口。完成后会显示落点目录。
    echo.
    "%PY%" "%KIT%\scripts\1-备份.py" --run
    goto done
)
goto menu

:m3
cls
%PSRUN% "%KIT%\scripts\12-准备离线包.ps1"
goto done

:m4
cls
%PSRUN% "%KIT%\scripts\7-做U盘.ps1"
goto done

:m5
cls
%PSRUN% "%KIT%\scripts\8-重启进U盘.ps1"
goto done

:m6
cls
call "%KIT%\bootstrap.cmd"
goto done

:m7
cls
%PSRUN% "%KIT%\scripts\9-收尾.ps1"
goto done

:m8
cls
echo.
echo ================================================================
echo    危险：回收 Dell 恢复分区
echo ================================================================
echo.
echo    这个操作会删除 NVMe 上的三个 Dell 恢复分区，把 18 GB 并回 C 盘。
echo    删除后：
echo      - F12 里的 Factory Image Restore 一键入口永久消失
echo      - 只能靠 D:\Reinstall_Kit\DellFactoryImage 手工还原
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

:m9
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

:m20
cls
echo.
echo   内存瘦身 / explorer 守护（Win11 专用，辅助脚本）：
echo    1  内存瘦身 · 只看报告（30 秒采样）
echo    2  内存瘦身 · 执行（关服务/启动项前会问你）
echo    0  返回
echo.
set "S="
set /p S=选择:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\20-内存瘦身.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\20-内存瘦身.ps1" -Apply
    goto done
)
goto menu

:m21
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
    %PSRUN% "%KIT%\scripts\21-explorer守护.ps1" -Status
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\21-explorer守护.ps1" -Restart
    goto done
)
goto menu

:m22
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
    %PSRUN% "%KIT%\scripts\22-回收内存.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\22-回收内存.ps1" -Apply
    goto done
)
goto menu

:m12
cls
%PSRUN% "%KIT%\scripts\13-拷到WePE盘.ps1"
goto done

:m13
cls
if not defined PY (
    echo [错误] 没找到 python，无法运行 Joplin 备份脚本
    goto done
)
echo   正在给 Joplin 做一致性快照（Joplin 可以开着）...
echo.
"%PY%" "%KIT%\scripts\15-备份Joplin.py" --run
goto done

:m14
cls
if not defined PY (
    echo [错误] 没找到 python，无法运行 Joplin 备份脚本
    goto done
)
echo.
echo   完整备份：会连 4.5 GB 附件一起拷，预计 3~10 分钟。
echo.
"%PY%" "%KIT%\scripts\15-备份Joplin.py" --run --with-resources
goto done

:m15
cls
echo   校验 37 条链接指向是否正确，以及 Joplin 库/附件能否真读到。
echo   装任何程序之前都应该先跑这个；链接不对就装，数据会写到 C 盘。
echo.
echo     1   只校验（默认）
echo     2   校验 + 发现异常时自动重建链接
echo.
set /p S=选择（直接回车=1）: 
if /i "%S%"=="2" goto m15fix
%PSRUN% "%KIT%\scripts\16-校验链接.ps1"
goto done

:m15fix
%PSRUN% "%KIT%\scripts\16-校验链接.ps1" -Fix
goto done

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
