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
# SSH SOCKS5 proxy tunnel with auto-reconnection and health checks
$LogFile = "SCRIPTS_DIR_PLACEHOLDER\tunnel-proxy.log"

function Test-SocksProxy {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", SOCKS_PORT_PLACEHOLDER)
        $tcp.Close()
        return $true
    } catch {
        return $false
    }
}

while ($true) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Connecting to SSH_SERVER_PLACEHOLDER..."

    # Start SSH as a hidden background process (no console window)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ssh"
    $psi.Arguments = "-D SOCKS_PORT_PLACEHOLDER -q -C -N -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ExitOnForwardFailure=yes -o TCPKeepAlive=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o BatchMode=yes -i `"SSH_KEY_PLACEHOLDER`" SSH_USER_PLACEHOLDER@SSH_SERVER_PLACEHOLDER"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $sshProc = [System.Diagnostics.Process]::Start($psi)

    # Wait for tunnel to come up (up to 15 seconds)
    $ready = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        if ($sshProc.HasExited) { break }
        if (Test-SocksProxy) { $ready = $true; break }
    }

    if ($ready) {
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Connected. SOCKS proxy active on port SOCKS_PORT_PLACEHOLDER."
        # Health check loop: verify tunnel every 30 seconds
        while (-not $sshProc.HasExited) {
            Start-Sleep -Seconds 30
            if ($sshProc.HasExited) { break }
            if (-not (Test-SocksProxy)) {
                Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Health check FAILED. Killing stale SSH process..."
                try { $sshProc.Kill() } catch {}
                break
            }
        }
    } else {
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Tunnel failed to come up within 15 seconds."
        if (-not $sshProc.HasExited) {
            try { $sshProc.Kill() } catch {}
        }
    }

    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Disconnected (exit code: $($sshProc.ExitCode)). Restarting in 5 seconds..."
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

# VBScript launcher to run PowerShell with no visible window
$TunnelVbs = "CreateObject(`"Wscript.Shell`").Run `"powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$TunnelScriptPath`"`"`", 0, False"
$TunnelVbsPath = Join-Path $ScriptsDir "tunnel-proxy.vbs"
$TunnelVbs | Set-Content -Path $TunnelVbsPath -Encoding ASCII

# Register scheduled task
$TaskName = "ssh-socks-proxy"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute "wscript.exe" `
    -Argument "`"$TunnelVbsPath`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Settings $Settings -Description "SSH SOCKS5 proxy tunnel" | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "SSH SOCKS proxy installed: socks5://127.0.0.1:$SOCKS_PORT" -ForegroundColor Green

# --- Optional: Xray VLESS+Reality (DPI-resistant tunnel) ---
if ($XRAY_UUID -and $XRAY_PUBLIC_KEY -and $XRAY_SHORT_ID) {
    Write-Host "Installing Xray VLESS+Reality tunnel..."

    if (-not $XRAY_SNI) { $XRAY_SNI = "www.google.com" }
    if (-not $XRAY_SERVER_PORT) { $XRAY_SERVER_PORT = "443" }

    # Find or install xray-core
    $XrayBin = (Get-Command xray -ErrorAction SilentlyContinue).Source
    if (-not $XrayBin) {
        $XrayBin = Join-Path $ScriptsDir "xray\xray.exe"
    }

    if (-not (Test-Path $XrayBin)) {
        Write-Host "Downloading xray-core..."
        $XrayDir = Join-Path $ScriptsDir "xray"
        New-Item -ItemType Directory -Path $XrayDir -Force | Out-Null

        $XrayRelease = Invoke-RestMethod "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
        $XrayAsset = $XrayRelease.assets | Where-Object { $_.name -match "Xray-windows-64\.zip$" } | Select-Object -First 1
        $XrayZip = Join-Path $env:TEMP "xray.zip"
        Invoke-WebRequest -Uri $XrayAsset.browser_download_url -OutFile $XrayZip
        Expand-Archive -Path $XrayZip -DestinationPath $XrayDir -Force
        Remove-Item $XrayZip
        $XrayBin = Join-Path $XrayDir "xray.exe"

        if (-not (Test-Path $XrayBin)) {
            Write-Host "Error: xray.exe not found after download" -ForegroundColor Red
            exit 1
        }
    }

    # Write client config
    $XrayConfigDir = Join-Path $ScriptsDir "xray"
    New-Item -ItemType Directory -Path $XrayConfigDir -Force | Out-Null

    $XrayConfig = @"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SSH_SERVER",
            "port": $XRAY_SERVER_PORT,
            "users": [
              {
                "id": "$XRAY_UUID",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$XRAY_SNI",
          "publicKey": "$XRAY_PUBLIC_KEY",
          "shortId": "$XRAY_SHORT_ID",
          "fingerprint": "chrome"
        }
      },
      "tag": "proxy"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
"@
    $XrayConfigPath = Join-Path $XrayConfigDir "config.json"
    $XrayConfig | Set-Content -Path $XrayConfigPath -Encoding UTF8

    # Xray launcher script
    $XrayScript = @"
`$LogFile = "$ScriptsDir\tunnel-xray.log"
while (`$true) {
    Add-Content -Path `$LogFile -Value "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Starting Xray..."
    `$psi = New-Object System.Diagnostics.ProcessStartInfo
    `$psi.FileName = "$XrayBin"
    `$psi.Arguments = "run -config `"$XrayConfigPath`""
    `$psi.UseShellExecute = `$false
    `$psi.CreateNoWindow = `$true
    `$psi.RedirectStandardOutput = `$true
    `$psi.RedirectStandardError = `$true
    `$proc = [System.Diagnostics.Process]::Start(`$psi)
    `$proc.WaitForExit()
    Add-Content -Path `$LogFile -Value "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Xray exited (code: `$(`$proc.ExitCode)). Restarting in 5 seconds..."
    Start-Sleep -Seconds 5
}
"@
    $XrayScriptPath = Join-Path $ScriptsDir "tunnel-xray.ps1"
    $XrayScript | Set-Content -Path $XrayScriptPath -Encoding UTF8

    # VBScript launcher
    $XrayVbs = "CreateObject(`"Wscript.Shell`").Run `"powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$XrayScriptPath`"`"`", 0, False"
    $XrayVbsPath = Join-Path $ScriptsDir "tunnel-xray.vbs"
    $XrayVbs | Set-Content -Path $XrayVbsPath -Encoding ASCII

    # Stop SSH tunnel task, register Xray task
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    $XrayTaskName = "xray-socks-proxy"
    Unregister-ScheduledTask -TaskName $XrayTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $XrayAction = New-ScheduledTaskAction -Execute "wscript.exe" `
        -Argument "`"$XrayVbsPath`""

    Register-ScheduledTask -TaskName $XrayTaskName -Action $XrayAction -Trigger $Trigger `
        -Settings $Settings -Description "Xray VLESS+Reality SOCKS5 proxy tunnel" | Out-Null
    Start-ScheduledTask -TaskName $XrayTaskName

    Write-Host "Xray VLESS+Reality installed (primary): socks5://127.0.0.1:$SOCKS_PORT" -ForegroundColor Green
    Write-Host "   SSH tunnel stopped (available as fallback)"
}

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
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "PPROXY_PATH_PLACEHOLDER"
    $psi.Arguments = "-r socks://127.0.0.1:SOCKS_PORT_PLACEHOLDER -l http://:HTTP_PORT_PLACEHOLDER"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
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

    # VBScript launcher for pproxy
    $PproxyVbs = "CreateObject(`"Wscript.Shell`").Run `"powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$PproxyScriptPath`"`"`", 0, False"
    $PproxyVbsPath = Join-Path $ScriptsDir "pproxy.vbs"
    $PproxyVbs | Set-Content -Path $PproxyVbsPath -Encoding ASCII

    $PproxyTaskName = "ssh-socks-pproxy"
    Unregister-ScheduledTask -TaskName $PproxyTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $PproxyAction = New-ScheduledTaskAction -Execute "wscript.exe" `
        -Argument "`"$PproxyVbsPath`""

    Register-ScheduledTask -TaskName $PproxyTaskName -Action $PproxyAction -Trigger $Trigger `
        -Settings $Settings -Description "HTTP proxy (SOCKS5 to HTTP via pproxy)" | Out-Null
    Start-ScheduledTask -TaskName $PproxyTaskName

    Write-Host "HTTP proxy installed: http://127.0.0.1:$HTTP_PORT" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done! Your proxy tunnel will auto-start on logon." -ForegroundColor Green
Write-Host ""
Write-Host "Useful commands:"
if ($XRAY_UUID -and $XRAY_PUBLIC_KEY -and $XRAY_SHORT_ID) {
    Write-Host "  Xray status:   Get-ScheduledTask -TaskName 'xray-socks-proxy'"
    Write-Host "  Xray logs:     Get-Content ~\scripts\tunnel-xray.log -Tail 20 -Wait"
    Write-Host "  Xray restart:  Stop-ScheduledTask -TaskName 'xray-socks-proxy'; Start-ScheduledTask -TaskName 'xray-socks-proxy'"
    Write-Host ""
    Write-Host "  Switch to SSH fallback:"
    Write-Host "    Stop-ScheduledTask -TaskName 'xray-socks-proxy'"
    Write-Host "    Start-ScheduledTask -TaskName 'ssh-socks-proxy'"
    Write-Host ""
    Write-Host "  Switch back to Xray:"
    Write-Host "    Stop-ScheduledTask -TaskName 'ssh-socks-proxy'"
    Write-Host "    Start-ScheduledTask -TaskName 'xray-socks-proxy'"
} else {
    Write-Host "  Check status:  Get-ScheduledTask -TaskName 'ssh-socks-proxy'"
    Write-Host "  View logs:     Get-Content ~\scripts\tunnel-proxy.log -Tail 20 -Wait"
    Write-Host "  Stop:          Stop-ScheduledTask -TaskName 'ssh-socks-proxy'"
    Write-Host "  Restart:       Stop-ScheduledTask -TaskName 'ssh-socks-proxy'; Start-ScheduledTask -TaskName 'ssh-socks-proxy'"
}
