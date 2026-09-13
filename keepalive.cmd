@echo off
rem keepalive entry (cmd/PowerShell). bash users: see the extensionless shim.
powershell.exe -noProfile -ExecutionPolicy Bypass -File "%~dp0keepalive-launch.ps1" %*
