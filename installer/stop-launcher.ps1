$p='*'+$env:BL_DIR+'\Launcher.ps1*';Get-CimInstance Win32_Process|?{$_.Name -eq 'powershell.exe' -and $_.CommandLine -like $p}|%{Stop-Process -Id $_.ProcessId -Force}
