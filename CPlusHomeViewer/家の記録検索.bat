@echo off
rem Opens the home record search page (home_search_server.ps1 serves it). Double-click this file.
rem The reader runs in a minimized window; closing that window stops the page.
start "" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0home_search_server.ps1"
