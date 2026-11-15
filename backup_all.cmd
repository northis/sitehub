@echo off
rem Manual run; the scheduled task calls backup_all.ps1 directly.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_all.ps1"
