@echo off
rem cmd.exe から claude-sync を呼ぶためのラッパー
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-sync.ps1" %*
