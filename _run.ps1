param([string]$cmd, [string]$tag)
$d="$env:USERPROFILE\Documents\MobileIntrusionDetection"
$log="$d\_log_$tag.txt"; $done="$d\_done_$tag.txt"
Remove-Item $log,$done -ErrorAction SilentlyContinue
$m = "cd('$d'); diary('$log'); try, $cmd, catch e, disp(getReport(e,'extended','hyperlinks','off')); end; diary off; fclose(fopen('$done','w'));"
Start-Process -FilePath "C:\Program Files\MATLAB\R2024a\bin\matlab.exe" -ArgumentList '-batch', "`"$m`"" -WindowStyle Hidden
