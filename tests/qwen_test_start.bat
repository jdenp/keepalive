@echo off
rem test wrapper: point the qwen hook at the dummy server
set QWEN_SERVER=C:\Repos\keepalive\tests\dummy_server.bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Repos\keepalive\hooks\qwen\start.ps1
