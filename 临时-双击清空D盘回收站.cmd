@echo off
chcp 936 >nul 2>&1
title 清空 D 盘回收站
echo.
echo   本脚本直接按文件系统清空 D 盘回收站（覆盖所有账户），
echo   比 Explorer 的「清空回收站」快百倍，删除前会要求输入盘符确认。
echo   正在请求管理员权限（UAC 弹窗请点「是」）...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\清空回收站.ps1" -DriveLetter D
echo.
