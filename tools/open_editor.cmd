@echo off
:: Opens the Stonkport project folder in the Godot editor (detached).
:: Override the engine binary by setting the GODOT environment variable.

setlocal
set "GODOT_EXE=Z:\Godot\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64.exe"
if defined GODOT set "GODOT_EXE=%GODOT%"

start "Godot Editor" "%GODOT_EXE%" -e --path "%~dp0.."
exit /b 0
