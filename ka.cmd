@echo off
rem keepalive entry (cmd/PowerShell). bash users: see the extensionless "ka" shim.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ka-launch.ps1" %*
