# AmneziaWG Router Proxy

DPI-resistant SOCKS5 proxy running on an ASUS router. Bypasses Russian ТСПУ internet censorship without requiring VPN apps on client devices.

**How it works:** An ASUS RT-AX88U Pro router runs an AmneziaWG tunnel to a foreign VPS and exposes a SOCKS5 proxy on the LAN. Any device on the network can route traffic through the tunnel — no VPN software needed on the device itself.

## Setup

### Prerequisites

- ASUS router with [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware
- USB drive plugged into the router (for Entware)
- VPS with [AmneziaVPN](https://amnezia.org/) server (AmneziaWG protocol)

### Client Setup

**Browser:** Install [SwitchyOmega](https://chrome.google.com/webstore/detail/proxy-switchyomega/padekgcemlokbadohgkifijomclgjgif) extension, create a profile:
- Protocol: `SOCKS5`
- Server: `192.168.50.1`
- Port: `8090`

**HTTP proxy** (for CLI tools, Docker, Claude Code, etc.):

macOS:
```bash
./setup-pproxy.sh
```

Windows (PowerShell as Administrator):
```powershell
powershell -ExecutionPolicy Bypass -File setup-pproxy.ps1
```

This installs [pproxy](https://github.com/qwj/python-proxy) which converts the router's SOCKS5 to HTTP on `127.0.0.1:8091`. Add to your shell profile:

```bash
# macOS (~/.zshrc)
export HTTP_PROXY="http://127.0.0.1:8091"
export HTTPS_PROXY="http://127.0.0.1:8091"
export NO_PROXY="localhost,127.0.0.1,192.168.50.0/24"
```

```powershell
# Windows (PowerShell, run as Admin)
[Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://127.0.0.1:8091', 'User')
[Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://127.0.0.1:8091', 'User')
[Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1,192.168.50.0/24', 'User')
```

## Usage

Switch VPS servers from any Mac terminal:

```bash
vpn status    # show tunnel status and verify proxy
vpn dk        # switch to Denmark
vpn nl        # switch to Netherlands
vpn kg        # switch to Kyrgyzstan
vpn list      # list available servers
vpn stop      # stop tunnel
```

The `vpn` alias is defined in `~/.zshrc`. The script SSHs into the router and runs `awg-manage`.

### Testing

```bash
# Test SOCKS5 directly
curl -x socks5h://192.168.50.1:8090 https://ifconfig.me

# Test HTTP proxy
curl -x http://127.0.0.1:8091 https://ifconfig.me
```

## Router Administration

SSH into the router:
```bash
ssh -p 22 admin@192.168.50.1
```

Management commands (on the router):
```bash
export PATH=/opt/bin:/opt/sbin:$PATH
awg-manage status
awg-manage list
awg-manage switch dk
awg-manage stop
```

### Key files on the router

| Path | Purpose |
|------|---------|
| `/opt/sbin/awg-manage` | Tunnel management script |
| `/opt/sbin/amneziawg-go` | AmneziaWG userspace binary |
| `/opt/etc/amneziawg/awg-*.conf` | Server configs (dk, nl, kg) |
| `/jffs/scripts/services-start` | Boot persistence |
| `/tmp/mnt/Kingston/entware.img` | Entware filesystem (ext3 on NTFS) |

### Adding a new VPS server

1. Set up AmneziaWG on the VPS via AmneziaVPN app
2. On the VPS, generate a keypair and add as peer:
   ```bash
   docker exec amnezia-awg wg genkey  # save as PRIVKEY
   echo PRIVKEY | docker exec -i amnezia-awg wg pubkey  # save as PUBKEY
   # Add peer with the PUBKEY and assign an IP
   ```
3. Create config on router at `/opt/etc/amneziawg/awg-<name>.conf`
4. Switch to it: `awg-manage switch <name>`

## Architecture

```
                    Internet (DPI/ТСПУ)
                         |
                    ASUS RT-AX88U Pro (192.168.50.1)
                    ├── AmneziaWG tunnel (awg0) ──── VPS
                    ├── Dante sockd (SOCKS5 :8090)
                    └── Merlin + Entware (USB)
                         |
                    LAN (192.168.50.0/24)
                    ├── Mac ── SwitchyOmega / pproxy
                    ├── Windows PC ── SwitchyOmega / pproxy
                    └── Other devices
```

The AmneziaWG protocol adds junk packets and header obfuscation to WireGuard, making it undetectable by DPI. The tunnel runs on the router using `amneziawg-go` (userspace Go implementation), so no kernel module is needed.

Traffic flow: `App → SOCKS5 (router:8090) → sockd → awg0 → VPS → internet`

For apps that only support HTTP proxy: `App → pproxy (localhost:8091) → SOCKS5 (router:8090) → tunnel`

## Resilience

- **Auto-start on boot:** `/jffs/scripts/services-start` mounts Entware and starts the last-used tunnel
- **KeepAlive:** AmneziaWG maintains persistent connections with 25s keepalive
- **Server switching:** If one VPS is slow or blocked, switch with `vpn <server>`
