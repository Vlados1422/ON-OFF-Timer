@echo off
rem Fallback launcher (a minimized console window stays in the taskbar while the program runs). Nothing is installed.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ONOFF-Timer.ps1"
