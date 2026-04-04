#Requires -Version 5.1
# Uninstall local pproxy HTTP proxy (Windows)

Write-Host "Uninstalling pproxy..."

$TaskName = "pproxy-http"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
    -ErrorAction SilentlyContinue

$ScriptsDir = Join-Path $env:USERPROFILE "scripts"
foreach ($file in @("pproxy.ps1", "pproxy.vbs", "pproxy.log")) {
    Remove-Item (Join-Path $ScriptsDir $file) -ErrorAction SilentlyContinue
}

Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Remove environment variables if no longer needed:"
Write-Host "  [Environment]::SetEnvironmentVariable('HTTP_PROXY', `$null, 'User')"
Write-Host "  [Environment]::SetEnvironmentVariable('HTTPS_PROXY', `$null, 'User')"
Write-Host "  [Environment]::SetEnvironmentVariable('NO_PROXY', `$null, 'User')"
