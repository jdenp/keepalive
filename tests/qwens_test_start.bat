@echo off
rem test wrapper: point the qwens hook at the dummy server
set QWENS_SERVER=C:\Repos\keepalive\tests\dummy_server.bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Repos\keepalive\hooks\qwens\start.ps1