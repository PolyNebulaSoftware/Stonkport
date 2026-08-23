@echo off
:: Builds LocalStoport export presets via the Godot CLI.
:: Usage: export_presets.cmd [web|windows|all]   (default: all)
:: Override the engine binary by setting the GODOT environment variable.

setlocal EnableExtensions
set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=all"

set "GODOT_EXE=Z:\Godot\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe"
if defined GODOT set "GODOT_EXE=%GODOT%"

cd /d "%~dp0.." || exit /b 1

if /i "%TARGET%"=="web" goto :web
if /i "%TARGET%"=="windows" goto :windows
if /i "%TARGET%"=="all" goto :web
echo Usage: export_presets.cmd [web^|windows^|all] >&2
exit /b 2

:web
echo [export] Web preset -^> web_dist/
"%GODOT_EXE%" --headless --path . --export-release "Web" web_dist/index.html || goto :fail
if /i not "%TARGET%"=="all" goto :done

:windows
echo [export] Windows Exe preset -^> build/windows/LocalStoport.exe
if not exist "build\windows" mkdir "build\windows"
"%GODOT_EXE%" --headless --path . --export-release "Windows Exe" "build\windows\LocalStoport.exe" || goto :fail

:done
echo [export] Done.
exit /b 0

:fail
echo [export] FAILED. >&2
exit /b 1
