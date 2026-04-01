#Requires -Version 5.1

Write-Host "Uninstalling proxy tunnel..."

foreach ($task in @("xray-socks-proxy", "ssh-socks-pproxy")) {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}

$ScriptsDir = Join-Path $env:USERPROFILE "scripts"
foreach ($file in @("tunnel-xray.ps1", "tunnel-xray.vbs", "pproxy.ps1", "pproxy.vbs", "tunnel-xray.log", "pproxy.log")) {
    Remove-Item (Join-Path $ScriptsDir $file) -ErrorAction SilentlyContinue
}
$XrayDir = Join-Path $ScriptsDir "xray"
if (Test-Path $XrayDir) { Remove-Item $XrayDir -Recurse -Force }

Write-Host "Done" -ForegroundColor Green
