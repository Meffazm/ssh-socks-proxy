# SSH SOCKS Proxy

Auto-starting proxy tunnel with SOCKS5 and optional HTTP proxy.

Supports **macOS** (launchctl) and **Windows** (Task Scheduler).

Supports two tunnel modes:
- **Xray VLESS+Reality** (primary, recommended) — resistant to DPI/ТСПУ, traffic looks like normal HTTPS
- **SSH SOCKS tunnel** (fallback) — simple but detectable by DPI

## Quick Setup

```bash
git clone https://github.com/Meffazm/ssh-socks-proxy.git && cd ssh-socks-proxy
cp .env.template .env
# Edit .env with your SSH settings and Xray credentials
```

**macOS:**
```bash
./install.sh
```

**Windows** (PowerShell as Administrator):
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

## Requirements

- SSH key configured for passwordless connection to server (for SSH fallback)
- **macOS:** macOS Sequoia 15+ (Apple Silicon tested), [Homebrew](https://brew.sh) (for xray-core)
- **Windows:** Windows 10/11 with OpenSSH Client (built-in on Windows 11)

## Configuration (.env)

| Variable | Description | Example |
|----------|-------------|---------|
| `SSH_USER` | SSH username | `root` |
| `SSH_SERVER` | Server address | `my-server.com` |
| `SSH_KEY_FILE` | Path to SSH private key | `~/.ssh/id_ed25519` |
| `SOCKS_PORT` | SOCKS proxy port | `8090` |
| `HTTP_PORT` | HTTP proxy port (optional) | `8091` |
| `XRAY_UUID` | Xray client UUID | `2de4f840-...` |
| `XRAY_PUBLIC_KEY` | Xray Reality public key | `GbCtFi44n...` |
| `XRAY_SHORT_ID` | Xray Reality short ID | `2ad3457adffb3171` |
| `XRAY_SNI` | SNI for Reality (default: `www.google.com`) | `www.google.com` |
| `XRAY_SERVER_PORT` | Xray server port (default: `443`) | `443` |

When `XRAY_UUID`, `XRAY_PUBLIC_KEY`, and `XRAY_SHORT_ID` are set, Xray becomes the primary tunnel and SSH tunnel is stopped (but stays installed as fallback).

## Usage

After installation, the proxy automatically starts on system boot (macOS) or logon (Windows).

**SOCKS proxy:** `socks5://127.0.0.1:8090`

**HTTP proxy** (if enabled): `http://127.0.0.1:8091`

## Status & Debugging

### macOS

```bash
# Check Xray tunnel status (primary)
launchctl print gui/$(id -u)/tunnel-xray

# Check SSH tunnel status (fallback)
launchctl print gui/$(id -u)/tunnel-proxy

# Check pproxy status
launchctl print gui/$(id -u)/pproxy

# Check what's listening on proxy ports
lsof -i :8090 -i :8091 -P -n

# Test SOCKS5 proxy
curl --socks5-hostname 127.0.0.1:8090 https://httpbin.org/ip

# Test HTTP proxy
curl -x http://127.0.0.1:8091 https://httpbin.org/ip

# View logs
tail -f ~/scripts/tunnel-xray.log      # Xray
tail -f ~/scripts/tunnel-proxy.log     # SSH tunnel
tail -f ~/scripts/pproxy.log           # pproxy

# Restart services
launchctl kickstart -k gui/$(id -u)/tunnel-xray
launchctl kickstart -k gui/$(id -u)/tunnel-proxy
launchctl kickstart -k gui/$(id -u)/pproxy

# Switch to SSH fallback
launchctl bootout gui/$(id -u)/tunnel-xray
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/tunnel-proxy.plist

# Switch back to Xray
launchctl bootout gui/$(id -u)/tunnel-proxy
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/tunnel-xray.plist
```

### Windows

```powershell
# Check Xray tunnel status (primary)
Get-ScheduledTask -TaskName 'xray-socks-proxy'

# Check SSH tunnel status (fallback)
Get-ScheduledTask -TaskName 'ssh-socks-proxy'

# Check pproxy status
Get-ScheduledTask -TaskName 'ssh-socks-pproxy'

# Test SOCKS5 proxy
curl --socks5-hostname 127.0.0.1:8090 https://httpbin.org/ip

# Test HTTP proxy
curl -x http://127.0.0.1:8091 https://httpbin.org/ip

# View logs
Get-Content ~\scripts\tunnel-xray.log -Tail 20 -Wait     # Xray
Get-Content ~\scripts\tunnel-proxy.log -Tail 20 -Wait    # SSH tunnel
Get-Content ~\scripts\pproxy.log -Tail 20 -Wait          # pproxy

# Restart Xray
Stop-ScheduledTask -TaskName 'xray-socks-proxy'; Start-ScheduledTask -TaskName 'xray-socks-proxy'

# Switch to SSH fallback
Stop-ScheduledTask -TaskName 'xray-socks-proxy'
Start-ScheduledTask -TaskName 'ssh-socks-proxy'

# Switch back to Xray
Stop-ScheduledTask -TaskName 'ssh-socks-proxy'
Start-ScheduledTask -TaskName 'xray-socks-proxy'
```

## Windows GUI Alternative

Instead of the automated installer, you can use a GUI client on Windows:

### v2rayN (recommended)

1. Download [v2rayN](https://github.com/2dust/v2rayN/releases) (latest version)
2. Extract and run `v2rayN.exe`
3. Add server: **Servers > Add [VLESS]**
4. Fill in:
   - **Address:** your server IP
   - **Port:** `443`
   - **UUID:** your `XRAY_UUID` from `.env`
   - **Flow:** `xtls-rprx-vision`
   - **Encryption:** `none`
   - **Network:** `tcp`
   - **TLS:** `reality`
   - **SNI:** `www.google.com`
   - **Fingerprint:** `chrome`
   - **PublicKey:** your `XRAY_PUBLIC_KEY` from `.env`
   - **ShortId:** your `XRAY_SHORT_ID` from `.env`
5. Right-click the server > **Set as active server**
6. In system tray, enable **System Proxy** or configure apps to use `socks5://127.0.0.1:10808`

### Quick import via vless:// URI

Import into any Xray-compatible client (v2rayN, Nekoray, Streisand):

```
vless://XRAY_UUID@SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google.com&fp=chrome&pbk=XRAY_PUBLIC_KEY&sid=XRAY_SHORT_ID&type=tcp#tunnel
```

Replace `XRAY_UUID`, `SERVER_IP`, `XRAY_PUBLIC_KEY`, and `XRAY_SHORT_ID` with your values.

In v2rayN: **Servers > Import from clipboard**.

### Other Windows GUI clients

- [Nekoray](https://github.com/MatsuriDayo/nekoray/releases) — cross-platform GUI
- [Invisible Man XRay](https://github.com/InvisibleManVPN/InvisibleMan-XRayClient) — simple Windows GUI

## Uninstall

**macOS:**
```bash
./uninstall.sh
```

**Windows:**
```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

## Browser Setup

Recommended: **SwitchyOmega** extension for Chrome/Firefox:

1. Create a profile with settings:
   - Protocol: `SOCKS5`
   - Server: `127.0.0.1`
   - Port: `8090`

2. In auto-switch, add rules for desired domains

## HTTP Proxy (Optional)

Useful for apps without SOCKS support (e.g., Docker Desktop free version).

Set `HTTP_PORT=8091` in `.env` before installation.

Uses [pproxy](https://github.com/qwj/python-proxy) to convert SOCKS5 to HTTP. Installed automatically via [uv](https://github.com/astral-sh/uv) if not found.

## Server Setup

### Xray VLESS+Reality

Install Xray on your server (Ubuntu/Debian):

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

Generate credentials:

```bash
xray uuid            # -> your XRAY_UUID
xray x25519          # -> PrivateKey (server config) and PublicKey (client config)
openssl rand -hex 8  # -> your XRAY_SHORT_ID
```

Server config (`/usr/local/etc/xray/config.json`):

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "YOUR_UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.google.com:443",
        "serverNames": ["www.google.com"],
        "privateKey": "YOUR_PRIVATE_KEY",
        "shortIds": ["YOUR_SHORT_ID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
```

```bash
systemctl restart xray
systemctl enable xray
```

### Recommended server hardening

```bash
# Firewall (adjust ports to match your setup)
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 443/tcp
ufw enable

# Brute force protection
apt install fail2ban

# TCP BBR (better throughput)
modprobe tcp_bbr
echo "tcp_bbr" >> /etc/modules
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr
```

## Resilience & Auto-Recovery

Both Xray and SSH tunnels are configured for automatic recovery:

**macOS (launchctl):**
- `KeepAlive=true` — restart on any exit
- `ThrottleInterval=5` — wait 5 seconds between restart attempts

**Windows (Task Scheduler):**
- Runs at logon with no execution time limit
- Built-in reconnection loop with 5-second retry interval
- Runs hidden (no console window)

**SSH tunnel extras:**
- `ServerAliveInterval=15` + `ServerAliveCountMax=2` for fast dead connection detection
- Health check loop verifies SOCKS port every 30 seconds
- Kills stale SSH processes on health check failure
