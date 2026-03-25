#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load config
$EnvFile = Join-Path $ScriptDir ".env"
if (-not (Test-Path $EnvFile)) {
    Write-Host "Error: .env not found. Copy .env.template to .env and fill in your settings:" -ForegroundColor Red
    Write-Host "   copy .env.template .env"
    exit 1
}

Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $key, $value = $line -split '=', 2
        Set-Variable -Name $key.Trim() -Value $value.Trim() -Scope Script
    }
}

# Validate required settings
if (-not $SSH_USER -or -not $SSH_SERVER) {
    Write-Host "Error: SSH_USER and SSH_SERVER must be set in .env" -ForegroundColor Red
    exit 1
}

# Check SSH is available
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "Error: ssh not found. Install OpenSSH Client from Windows Settings > Apps > Optional Features" -ForegroundColor Red
    exit 1
}

# Expand ~ in path
$SSH_KEY_FILE = $SSH_KEY_FILE -replace '^~', $env:USERPROFILE
if (-not $SOCKS_PORT) { $SOCKS_PORT = "8090" }

$ScriptsDir = Join-Path $env:USERPROFILE "scripts"
New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null

# --- SOCKS Tunnel ---
Write-Host "Installing SOCKS proxy tunnel..."

$TunnelScript = @'
# SSH SOCKS5 proxy tunnel with auto-reconnection
$LogFile = "SCRIPTS_DIR_PLACEHOLDER\tunnel-proxy.log"

while ($true) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Connecting to SSH_SERVER_PLACEHOLDER..."
    $sshOutput = & ssh -D SOCKS_PORT_PLACEHOLDER -v -C -N `
        -o ServerAliveInterval=30 `
        -o ServerAliveCountMax=2 `
        -o ExitOnForwardFailure=yes `
        -o TCPKeepAlive=yes `
        -o ConnectTimeout=10 `
        -o ConnectionAttempts=1 `
        -o BatchMode=yes `
        -i "SSH_KEY_PLACEHOLDER" `
        SSH_USER_PLACEHOLDER@SSH_SERVER_PLACEHOLDER 2>&1
    $sshOutput | ForEach-Object { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') SSH: $_" }
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Disconnected (exit code: $LASTEXITCODE). Restarting in 5 seconds..."
    Start-Sleep -Seconds 5
}
'@

$TunnelScript = $TunnelScript -replace 'SCRIPTS_DIR_PLACEHOLDER', $ScriptsDir
$TunnelScript = $TunnelScript -replace 'SOCKS_PORT_PLACEHOLDER', $SOCKS_PORT
$TunnelScript = $TunnelScript -replace 'SSH_KEY_PLACEHOLDER', $SSH_KEY_FILE
$TunnelScript = $TunnelScript -replace 'SSH_USER_PLACEHOLDER', $SSH_USER
$TunnelScript = $TunnelScript -replace 'SSH_SERVER_PLACEHOLDER', $SSH_SERVER

$TunnelScriptPath = Join-Path $ScriptsDir "tunnel-proxy.ps1"
$TunnelScript | Set-Content -Path $TunnelScriptPath -Encoding UTF8

# Register scheduled task
$TaskName = "ssh-socks-proxy"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TunnelScriptPath`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Settings $Settings -Description "SSH SOCKS5 proxy tunnel" | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "SOCKS proxy installed: socks5://127.0.0.1:$SOCKS_PORT" -ForegroundColor Green

# --- Optional: HTTP Proxy (pproxy) ---
if ($HTTP_PORT) {
    Write-Host "Installing HTTP proxy (pproxy)..."

    # Find pproxy
    $PproxyPath = (Get-Command pproxy -ErrorAction SilentlyContinue).Source

    if (-not $PproxyPath) {
        foreach ($candidate in @(
            "$env:USERPROFILE\.local\bin\pproxy.exe"
            "$env:LOCALAPPDATA\Programs\Python\Python3*\Scripts\pproxy.exe"
            "$env:APPDATA\Python\Python3*\Scripts\pproxy.exe"
        )) {
            $found = Get-Item $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $PproxyPath = $found.FullName; break }
        }
    }

    if (-not $PproxyPath) {
        Write-Host "Installing pproxy with uv..."

        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
            Write-Host "uv not found; installing..."
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                winget install --id astral-sh.uv --accept-source-agreements --accept-package-agreements
            } else {
                Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
            }
            $env:PATH = "$env:USERPROFILE\.local\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"
            if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
                Write-Host "Error: uv installation failed" -ForegroundColor Red
                exit 1
            }
        }

        uv tool uninstall pproxy 2>$null
        uv tool install pproxy 2>$null
        $UvToolBin = (uv tool dir --bin).Trim()
        $PproxyPath = Join-Path $UvToolBin "pproxy.exe"
        if (-not (Test-Path $PproxyPath)) {
            Write-Host "Error: pproxy not found at: $PproxyPath" -ForegroundColor Red
            exit 1
        }
    }

    $PproxyScript = @'
# HTTP proxy via pproxy (SOCKS5 to HTTP conversion)
$LogFile = "SCRIPTS_DIR_PLACEHOLDER\pproxy.log"

while ($true) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Starting pproxy..."
    & "PPROXY_PATH_PLACEHOLDER" -r socks://127.0.0.1:SOCKS_PORT_PLACEHOLDER -l http://:HTTP_PORT_PLACEHOLDER
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') pproxy exited. Restarting in 5 seconds..."
    Start-Sleep -Seconds 5
}
'@

    $PproxyScript = $PproxyScript -replace 'SCRIPTS_DIR_PLACEHOLDER', $ScriptsDir
    $PproxyScript = $PproxyScript -replace 'PPROXY_PATH_PLACEHOLDER', $PproxyPath
    $PproxyScript = $PproxyScript -replace 'SOCKS_PORT_PLACEHOLDER', $SOCKS_PORT
    $PproxyScript = $PproxyScript -replace 'HTTP_PORT_PLACEHOLDER', $HTTP_PORT

    $PproxyScriptPath = Join-Path $ScriptsDir "pproxy.ps1"
    $PproxyScript | Set-Content -Path $PproxyScriptPath -Encoding UTF8

    $PproxyTaskName = "ssh-socks-pproxy"
    Unregister-ScheduledTask -TaskName $PproxyTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $PproxyAction = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PproxyScriptPath`""

    Register-ScheduledTask -TaskName $PproxyTaskName -Action $PproxyAction -Trigger $Trigger `
        -Settings $Settings -Description "HTTP proxy (SOCKS5 to HTTP via pproxy)" | Out-Null
    Start-ScheduledTask -TaskName $PproxyTaskName

    Write-Host "HTTP proxy installed: http://127.0.0.1:$HTTP_PORT" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done! Your proxy tunnel will auto-start on logon." -ForegroundColor Green
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Check status:  Get-ScheduledTask -TaskName 'ssh-socks-proxy'"
Write-Host "  View logs:     Get-Content ~\scripts\tunnel-proxy.log -Tail 20 -Wait"
Write-Host "  Stop:          Stop-ScheduledTask -TaskName 'ssh-socks-proxy'"
Write-Host "  Restart:       Stop-ScheduledTask -TaskName 'ssh-socks-proxy'; Start-ScheduledTask -TaskName 'ssh-socks-proxy'"
