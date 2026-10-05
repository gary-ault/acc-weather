@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" goto unsigned
if /I "%~1"=="unsigned" goto unsigned
if /I "%~1"=="signed" goto signed
echo Usage: build-plugin.bat [unsigned^|signed]
exit /b 2
:unsigned
python tools\package_plugin.py --plugin acc-weather
exit /b %ERRORLEVEL%
:signed
python tools\package_plugin.py --plugin acc-weather --create-signing-key
exit /b %ERRORLEVEL%
