# SSH SOCKS Proxy

Router-based AmneziaWG proxy tunnel. DPI-resistant SOCKS5 proxy runs on ASUS RT-AX88U Pro router, available to all LAN devices without VPN apps.

## Architecture

```
LAN devices -> Router (ASUS RT-AX88U Pro)
                 |-> AmneziaWG tunnel (awg0) -> VPS
                 |-> Dante sockd (SOCKS5 :8090)
               
Mac/Windows -> SOCKS5 (192.168.50.1:8090) -> tunnel -> VPS -> internet
            -> pproxy (127.0.0.1:8091) -> SOCKS5 -> tunnel (for HTTP_PROXY)
```

## Structure

- `vpn-switch.sh` — switch between VPS servers from Mac CLI
- `setup-pproxy.sh` — install local HTTP proxy on macOS
- `setup-pproxy.ps1` — install local HTTP proxy on Windows

### On the router (192.168.50.1)

- `/opt/sbin/awg-manage` — tunnel management script
- `/opt/sbin/amneziawg-go` — userspace AmneziaWG binary
- `/opt/etc/amneziawg/awg-{dk,nl,kg}.conf` — server configs
- `/opt/etc/sockd.conf` — Dante SOCKS5 config
- `/jffs/scripts/services-start` — boot persistence
- `/tmp/mnt/Kingston/entware.img` — Entware filesystem image

### VPS servers

- dk: 46.29.235.73 (Denmark)
- nl: 212.192.9.217 (Netherlands)
- kg: 188.240.213.228 (Kyrgyzstan)

All run AmneziaWG via Docker (`amnezia-awg` container).

## Quick commands

```bash
vpn status    # check tunnel + proxy
vpn dk        # switch to Denmark
vpn nl        # switch to Netherlands
vpn kg        # switch to Kyrgyzstan
vpn list      # list servers
vpn stop      # stop tunnel
```

## Decisions

- **AmneziaWG over Xray/SSH** — only protocol that reliably bypasses Russian DPI (ТСПУ)
- **Router-based tunnel** — works for all LAN devices, no VPN app needed, bypasses Cisco Secure Client restrictions
- **Userspace amneziawg-go** — kernel module not available for router's Linux 4.19
- **Dante sockd for SOCKS5** — reliable, supports binding to specific interface
- **pproxy for HTTP proxy** — converts SOCKS5 to HTTP for apps that don't support SOCKS
- **Entware on ext3 image file** — preserves existing NTFS data on USB drive
