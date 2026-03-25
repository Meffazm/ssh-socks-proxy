# SSH SOCKS Proxy

Auto-starting SSH tunnel with SOCKS5 proxy and optional HTTP proxy wrapper.

Supports **macOS** (launchctl) and **Windows** (Task Scheduler).

## Quick Setup

```bash
git clone https://github.com/Meffazm/ssh-socks-proxy.git && cd ssh-socks-proxy
cp .env.template .env
# Edit .env with your SSH settings
```

**macOS:**
```bash
./install.sh
```

**Windows** (PowerShell):
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

## Requirements

- SSH key configured for passwordless connection to server
- **macOS:** macOS Sequoia 15+ (Apple Silicon tested)
- **Windows:** Windows 10/11 with OpenSSH Client (built-in on Windows 11)

## Configuration (.env)

| Variable | Description | Example |
|----------|-------------|---------|
| `SSH_USER` | SSH username | `root` |
| `SSH_SERVER` | Server address | `my-server.com` |
| `SSH_KEY_FILE` | Path to SSH private key | `~/.ssh/id_ed25519` |
| `SOCKS_PORT` | SOCKS proxy port | `8090` |
| `HTTP_PORT` | HTTP proxy port (optional) | `8091` |

## Usage

After installation, the proxy automatically starts on system boot (macOS) or logon (Windows).

**SOCKS proxy:** `socks5://127.0.0.1:8090`

**HTTP proxy** (if enabled): `http://127.0.0.1:8091`

### macOS Commands

```bash
# Status
launchctl print gui/$(id -u)/tunnel-proxy

# Logs
tail -f ~/scripts/tunnel-proxy.log

# Restart
launchctl kickstart -k gui/$(id -u)/tunnel-proxy

# Stop
launchctl kill TERM gui/$(id -u)/tunnel-proxy
```

### Windows Commands

```powershell
# Status
Get-ScheduledTask -TaskName 'ssh-socks-proxy'

# Logs
Get-Content ~\scripts\tunnel-proxy.log -Tail 20 -Wait

# Restart
Stop-ScheduledTask -TaskName 'ssh-socks-proxy'; Start-ScheduledTask -TaskName 'ssh-socks-proxy'

# Stop
Stop-ScheduledTask -TaskName 'ssh-socks-proxy'
```

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

Just set `HTTP_PORT=8091` in `.env` before installation.

Uses [pproxy](https://github.com/qwj/python-proxy) to convert SOCKS5 to HTTP. Installed automatically via [uv](https://github.com/astral-sh/uv) if not found.

## Resilience & Auto-Recovery

The tunnel is configured for maximum reliability:

**SSH options:**
- `ServerAliveInterval=30` — send keepalive every 30 seconds
- `ServerAliveCountMax=2` — disconnect after 2 failed keepalives (~1 min max to detect dead connection)
- `TCPKeepAlive=yes` — enable TCP-level keepalive
- `ConnectTimeout=10` — fail fast if server unreachable
- `ExitOnForwardFailure=yes` — exit if port binding fails

**macOS (launchctl):**
- `KeepAlive.SuccessfulExit=false` — restart on any exit (crash or connection loss)
- `KeepAlive.NetworkState=true` — restart when network becomes available
- `ThrottleInterval=5` — wait 5 seconds between restart attempts

**Windows (Task Scheduler):**
- Runs at logon with no execution time limit
- Built-in reconnection loop with 5-second retry interval
- Runs hidden (no console window)
