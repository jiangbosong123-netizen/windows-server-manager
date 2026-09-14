@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut([Environment]::GetFolderPath('Desktop')+'\Windows Server Manager.lnk'); $s.TargetPath='%~dp0server-manager.cmd'; $s.WorkingDirectory='%~dp0'; $s.Save()"
echo Desktop shortcut created.
pause
