@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
set "EMPTY=0"
title Reinstall Kit - Windows 10 ��װ���̰�
color 0B

set "KIT=%~dp0"
if "%KIT:~-1%"=="\" set "KIT=%KIT:~0,-1%"

rem ---------- �Զ���Ȩ ----------
net session >nul 2>&1
if errorlevel 1 (
    if defined KIT_NOELEVATE (
        echo   [����ģʽ] ������Ȩ
    ) else (
        echo.
        echo   ��Ҫ����ԱȨ�ޣ����ڵ�����Ȩ���ڣ���㡸�ǡ�...
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
        exit /b
    )
)

rem ---------- �� python ----------
set "PY="
for %%P in (python.exe) do if not defined PY if exist "%%~$PATH:P" set "PY=%%~$PATH:P"
if not defined PY if exist "%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe" set "PY=%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe"
if not defined PY for %%P in (py.exe) do if not defined PY if exist "%%~$PATH:P" set "PY=%%~$PATH:P"

set "PSRUN=powershell -NoProfile -ExecutionPolicy Bypass -File"

:menu
cls
echo.
echo ================================================================
echo    Windows 10 ��װ���̰�
echo    ����Ŀ¼: %KIT%
echo ================================================================
echo.
echo   ��׼���׶� �� ������̨�������ܡ�
echo     1   ȫ������죨ֻ�������������
echo     2   ���� C ��©������
echo     3   ׼�� winget ���߰�
echo     4   ���� Ventoy ��װ�̣��������ֻ U �̣�
echo     12  �������� WePE �̣������������Ƽ���
echo     13  ���� Joplin �ʼǿ⣨��+����+�����Լ 190 MB��
echo     14  ���� Joplin���� 4.5 GB ��������һЩ��
echo     5   ��������� U �̰�װ
echo.
echo   ����װ֮��
echo     6   �ؽ����� + ����װ���
echo     15  У�����������ݿɴװ����ǰ���ܣ�
echo     7   ��β��飨����/����/���ݻָ���
echo.
echo   ��Σ�ղ��� �� ��Ҫ����ȷ�ϡ�
echo     8   ���� Dell �ָ��������� 18GB ���� C �̣�
echo     9   �ӳ�������ԭϵͳ���ع���
echo.
echo   ���ճ�ά����
echo    10   �ڴ����� / explorer �ػ�
echo    11   �������ύ�ڴ�
echo.
echo     0   �Լ����нű������˽ű�֮���ܣ�
echo     H   ����װ���ֲ�
echo     Q   �˳�
echo.
set "CH="
set /p CH=�������ź�س�:
if not defined CH (
    set /a "EMPTY+=1"
    if !EMPTY! geq 3 (
        echo.
        echo   ���������룬�˳���
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
if /i "%CH%"=="0" goto m0
if /i "%CH%"=="H" goto mh
if /i "%CH%"=="Q" exit /b 0
goto menu

rem ================================================================
:m1
cls
%PSRUN% "%KIT%\scripts\0-���.ps1"
goto done

:m2
cls
echo.
echo  �����������ܷ���
echo    1  �ȿ��ƻ��������κ��ļ���
echo    2  ֱ�ӿ�ʼ���ݣ�Լ 4.8 GB��10~30 ���ӣ�
echo    0  ����
echo.
set "S="
set /p S=ѡ��:
if "%S%"=="1" (
    if not defined PY (
        echo [����] û�ҵ� python���޷����б��ݽű�
        goto done
    )
    "%PY%" "%KIT%\scripts\1-����.py"
    goto done
)
if "%S%"=="2" (
    if not defined PY (
        echo [����] û�ҵ� python���޷����б��ݽű�
        goto done
    )
    echo.
    echo   ��ʼ���ݣ��ڼ䲻Ҫ�رմ��ڡ���ɺ����ʾ���Ŀ¼��
    echo.
    "%PY%" "%KIT%\scripts\1-����.py" --run
    goto done
)
goto menu

:m3
cls
%PSRUN% "%KIT%\scripts\12-׼�����߰�.ps1"
goto done

:m4
cls
%PSRUN% "%KIT%\scripts\7-��U��.ps1"
goto done

:m5
cls
%PSRUN% "%KIT%\scripts\8-�����U��.ps1"
goto done

:m6
cls
call "%KIT%\bootstrap.cmd"
goto done

:m7
cls
%PSRUN% "%KIT%\scripts\9-��β.ps1"
goto done

:m8
cls
echo.
echo ================================================================
echo    Σ�գ����� Dell �ָ�����
echo ================================================================
echo.
echo    ���������ɾ�� NVMe �ϵ����� Dell �ָ��������� 18 GB ���� C �̡�
echo    ɾ����
echo      - F12 ��� Factory Image Restore һ�����������ʧ
echo      - ֻ�ܿ� D:\Reinstall_Kit\DellFactoryImage �ֹ���ԭ
echo.
echo    �ű��Լ����飺ϵͳ�ǲ�������װ�������ǲ���������
echo    �����ǲ������ Dell ���������κ�һ�������㶼��ܾ�ִ�С�
echo.
echo    �ű��ﻹ���ĵ��˹�ȷ�ϣ�DELETE / ɾ���ָ����� / ����ʱ����
echo.
set "DC="
set /p DC=������Ѿ������������ DANGER ������ֱ�ӻس����أ�:
if /i not "%DC%"=="DANGER" goto menu
cls
%PSRUN% "%KIT%\scripts\10-���ջָ�����.ps1" -Apply
goto done

:m9
cls
echo.
echo   ����"�ع�������ϵͳ"�õģ�������һ�� WinPE �����е��������
echo    1  ��鱸�������Բ����� ��ԭ����ϵͳ.cmd
echo    2  ˳���� SHA256 ���У�飨16 ���ӣ�
echo    0  ����
echo.
set "S="
set /p S=ѡ��:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\11-��������ԭ.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\11-��������ԭ.ps1" -DeepVerify
    goto done
)
goto menu

:m10
cls
echo.
echo   �ڴ�ά����
echo    1  �ڴ����� �� ֻ�����棨30 �������
echo    2  �ڴ����� �� ִ�У��ط���/�����ǰ�����㣩
echo    3  explorer ����ػ� �� ��״̬
echo    4  explorer ����ػ� �� �������� explorer
echo    0  ����
echo.
set "S="
set /p S=ѡ��:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\4-�ڴ�����.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\4-�ڴ�����.ps1" -Apply
    goto done
)
if "%S%"=="3" (
    %PSRUN% "%KIT%\scripts\5-explorer�ػ�.ps1" -Status
    goto done
)
if "%S%"=="4" (
    %PSRUN% "%KIT%\scripts\5-explorer�ػ�.ps1" -Restart
    goto done
)
goto menu

:m11
cls
echo.
echo   �������ύ�ڴ棺
echo    1  ������ֻ���棬�����֣�
echo    2  ִ�У��� MSBuild / Joplin ��̨���̣�
echo    0  ����
echo.
set "S="
set /p S=ѡ��:
if "%S%"=="1" (
    %PSRUN% "%KIT%\scripts\6-�����ڴ�.ps1"
    goto done
)
if "%S%"=="2" (
    %PSRUN% "%KIT%\scripts\6-�����ڴ�.ps1" -Apply
    goto done
)
goto menu

:m12
cls
%PSRUN% "%KIT%\scripts\13-����WePE��.ps1"
goto done

:m13
cls
if not defined PY (
    echo [����] û�ҵ� python���޷����� Joplin ���ݽű�
    goto done
)
echo   ���ڸ� Joplin ��һ���Կ��գ�Joplin ���Կ��ţ�...
echo.
"%PY%" "%KIT%\scripts\15-����Joplin.py" --run
goto done

:m14
cls
if not defined PY (
    echo [����] û�ҵ� python���޷����� Joplin ���ݽű�
    goto done
)
echo.
echo   �������ݣ����� 4.5 GB ����һ�𿽣�Ԥ�� 3~10 ���ӡ�
echo.
"%PY%" "%KIT%\scripts\15-����Joplin.py" --run --with-resources
goto done

:m15
cls
echo   У�� 37 ������ָ���Ƿ���ȷ���Լ� Joplin ��/�����ܷ��������
echo   װ�κγ���֮ǰ��Ӧ��������������Ӳ��Ծ�װ�����ݻ�д�� C �̡�
echo.
echo     1   ֻУ�飨Ĭ�ϣ�
echo     2   У�� + �����쳣ʱ�Զ��ؽ�����
echo.
set /p S=ѡ��ֱ�ӻس�=1��: 
if /i "%S%"=="2" goto m15fix
%PSRUN% "%KIT%\scripts\16-У������.ps1"
goto done

:m15fix
%PSRUN% "%KIT%\scripts\16-У������.ps1" -Fix
goto done

:m0
cls
%PSRUN% "%KIT%\scripts\99-�Լ�.ps1"
goto done

:mh
start "" "%KIT%\00-��װ���ֲ�.md"
goto menu

:done
echo.
echo ----------------------------------------------------------------
echo   �����������������������˵���
echo ----------------------------------------------------------------
pause >nul
goto menu
