#Requires -Version 5.1

Write-Host "Uninstalling proxy tunnel..."

foreach ($task in @("ssh-socks-proxy", "ssh-socks-pproxy")) {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}

$ScriptsDir = Join-Path $env:USERPROFILE "scripts"
foreach ($file in @("tunnel-proxy.ps1", "pproxy.ps1", "tunnel-proxy.log", "pproxy.log")) {
    Remove-Item (Join-Path $ScriptsDir $file) -ErrorAction SilentlyContinue
}

Write-Host "Done" -ForegroundColor Green
