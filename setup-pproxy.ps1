#Requires -Version 5.1
# Install pproxy as HTTP-to-SOCKS5 converter (Windows)
# Converts router's SOCKS5 proxy to HTTP for apps that don't support SOCKS
# (e.g., Claude Code, Docker Desktop, npm, pip)

$ErrorActionPreference = "Stop"

$Router = "192.168.50.1"
$SocksPort = 8090
$HttpPort = 8091
$ScriptsDir = Join-Path $env:USERPROFILE "scripts"

Write-Host "Setting up HTTP proxy (pproxy) on Windows..."

# Find or install pproxy
$PproxyPath = (Get-Command pproxy -ErrorAction SilentlyContinue).Source

if (-not $PproxyPath) {
    foreach ($candidate in @(
        "$env:USERPROFILE\.local\bin\pproxy.exe"
        "$env:LOCALAPPDATA\Programs\Python\Python3*\Scripts\pproxy.exe"
        "$env:APPDATA\Python\Python3*\Scripts\pproxy.exe"
    )) {
        $found = Get-Item $candidate -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { $PproxyPath = $found.FullName; break }
    }
}

if (-not $PproxyPath) {
    Write-Host "Installing pproxy..."

    # Ensure uv is available (preferred installer)
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Host "uv not found, installing..."
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id astral-sh.uv `
                --accept-source-agreements `
                --accept-package-agreements
        } else {
            Invoke-RestMethod https://astral.sh/uv/install.ps1 |
                Invoke-Expression
        }
        $env:PATH = "$env:USERPROFILE\.local\bin;" +
            "$env:USERPROFILE\.cargo\bin;$env:PATH"
    }

    if (Get-Command uv -ErrorAction SilentlyContinue) {
        uv tool uninstall pproxy 2>$null
        uv tool install pproxy 2>$null
        $UvBin = (uv tool dir --bin).Trim()
        $PproxyPath = Join-Path $UvBin "pproxy.exe"
    } elseif (Get-Command pip3 -ErrorAction SilentlyContinue) {
        pip3 install --user pproxy 2>$null
        $PproxyPath = (Get-Command pproxy `
            -ErrorAction SilentlyContinue).Source
    } elseif (Get-Command pip -ErrorAction SilentlyContinue) {
        pip install --user pproxy 2>$null
        $PproxyPath = (Get-Command pproxy `
            -ErrorAction SilentlyContinue).Source
    } else {
        Write-Host "Error: failed to install uv or find pip" `
            -ForegroundColor Red
        exit 1
    }
}

if (-not $PproxyPath -or -not (Test-Path $PproxyPath)) {
    Write-Host "Error: pproxy not found after installation" -ForegroundColor Red
    exit 1
}

Write-Host "pproxy found: $PproxyPath"

New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null

# Create PowerShell launcher script
$LauncherScript = @"
`$LogFile = "$ScriptsDir\pproxy.log"
while (`$true) {
    Add-Content -Path `$LogFile -Value "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Starting pproxy..."
    `$psi = New-Object System.Diagnostics.ProcessStartInfo
    `$psi.FileName = "$PproxyPath"
    `$psi.Arguments = "-r socks5://${Router}:${SocksPort} -l http://:${HttpPort}"
    `$psi.UseShellExecute = `$false
    `$psi.CreateNoWindow = `$true
    `$proc = [System.Diagnostics.Process]::Start(`$psi)
    `$proc.WaitForExit()
    Add-Content -Path `$LogFile -Value "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') pproxy exited. Restarting in 5s..."
    Start-Sleep -Seconds 5
}
"@
$LauncherPath = Join-Path $ScriptsDir "pproxy.ps1"
$LauncherScript | Set-Content -Path $LauncherPath -Encoding UTF8

# VBScript wrapper for hidden execution
$VbsPath = Join-Path $ScriptsDir "pproxy.vbs"
$Vbs = "CreateObject(`"Wscript.Shell`").Run `"powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$LauncherPath`"`"`", 0, False"
$Vbs | Set-Content -Path $VbsPath -Encoding ASCII

# Register scheduled task
$TaskName = "pproxy-http"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
    -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute "wscript.exe" `
    -Argument "`"$VbsPath`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

Register-ScheduledTask -TaskName $TaskName -Action $Action `
    -Trigger $Trigger -Settings $Settings `
    -Description "HTTP proxy (SOCKS5 to HTTP via pproxy)" | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "HTTP proxy installed: http://127.0.0.1:$HttpPort" `
    -ForegroundColor Green
Write-Host "  Forwards to: socks5://${Router}:${SocksPort} (router)"
Write-Host ""
Write-Host "Set environment variables (run in PowerShell as Admin):"
Write-Host "  [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://127.0.0.1:$HttpPort', 'User')"
Write-Host "  [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://127.0.0.1:$HttpPort', 'User')"
Write-Host "  [Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1,192.168.50.0/24', 'User')"
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Status:   Get-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Logs:     Get-Content ~\scripts\pproxy.log -Tail 20 -Wait"
Write-Host "  Restart:  Stop-ScheduledTask -TaskName '$TaskName'; Start-ScheduledTask -TaskName '$TaskName'"
