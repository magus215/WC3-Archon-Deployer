@echo off
rem Launch the Archon Deployer GUI. Double-click this file.
cd /d "%~dp0"
py gui.py && goto :eof
python gui.py && goto :eof
echo.
echo Could not start the Archon Deployer.
echo Python 3 is required - install it from https://www.python.org/downloads/
echo (during install, tick "Add Python to PATH"), then double-click this file again.
pause
