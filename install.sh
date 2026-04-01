#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "❌ .env not found. Copy .env.template to .env and fill in your settings:"
    echo "   cp .env.template .env"
    exit 1
fi
source "$SCRIPT_DIR/.env"

# Validate required settings
if [ -z "$SSH_USER" ] || [ -z "$SSH_SERVER" ]; then
    echo "❌ SSH_USER and SSH_SERVER must be set in .env"
    exit 1
fi

# Expand ~ in path
SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
SOCKS_PORT="${SOCKS_PORT:-8090}"

SCRIPTS_DIR="$HOME/scripts"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DOMAIN_TARGET="gui/$(id -u)"

mkdir -p "$SCRIPTS_DIR" "$LAUNCH_AGENTS"

# --- SOCKS Tunnel ---
echo "📦 Installing SOCKS proxy tunnel..."

cat > "$SCRIPTS_DIR/tunnel-proxy.sh" << 'SCRIPT_EOF'
#!/bin/sh
# Resilient SSH tunnel with auto-recovery and health checks
# - Starts SSH in background and monitors SOCKS port every 30s
# - Kills stale SSH if tunnel becomes unresponsive (e.g. after sleep/wake)
# - Exits so launchctl can restart the whole thing

LOG="SCRIPTS_DIR_PLACEHOLDER/tunnel-proxy.log"
PORT=SOCKS_PORT_PLACEHOLDER

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

check_socks() {
    # Try to open a TCP connection to the SOCKS port
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$PORT" 2>/dev/null
    else
        (echo > /dev/tcp/127.0.0.1/"$PORT") 2>/dev/null
    fi
}

log "Connecting to SSH_SERVER_PLACEHOLDER..."

ssh -D "$PORT" -q -C -N \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    -o ExitOnForwardFailure=yes \
    -o TCPKeepAlive=yes \
    -o ConnectTimeout=10 \
    -o ConnectionAttempts=1 \
    -o BatchMode=yes \
    -i "SSH_KEY_PLACEHOLDER" \
    SSH_USER_PLACEHOLDER@SSH_SERVER_PLACEHOLDER >> "$LOG" 2>&1 &

SSH_PID=$!

# Wait for tunnel to come up (up to 15 seconds)
READY=0
for i in $(seq 1 15); do
    sleep 1
    if ! kill -0 "$SSH_PID" 2>/dev/null; then break; fi
    if check_socks; then READY=1; break; fi
done

if [ "$READY" -eq 1 ]; then
    log "Connected. SOCKS proxy active on port $PORT."
    # Health check loop
    while kill -0 "$SSH_PID" 2>/dev/null; do
        sleep 30
        if ! kill -0 "$SSH_PID" 2>/dev/null; then break; fi
        if ! check_socks; then
            log "Health check FAILED. Killing stale SSH process..."
            kill "$SSH_PID" 2>/dev/null
            sleep 1
            kill -9 "$SSH_PID" 2>/dev/null
            break
        fi
    done
else
    log "Tunnel failed to come up within 15 seconds."
    kill "$SSH_PID" 2>/dev/null
    kill -9 "$SSH_PID" 2>/dev/null
fi

wait "$SSH_PID" 2>/dev/null
EXIT_CODE=$?
log "Disconnected (exit code: $EXIT_CODE)."
exit $EXIT_CODE
SCRIPT_EOF

# Replace placeholders with actual values
sed -i '' "s|SCRIPTS_DIR_PLACEHOLDER|$SCRIPTS_DIR|g" "$SCRIPTS_DIR/tunnel-proxy.sh"
sed -i '' "s|SOCKS_PORT_PLACEHOLDER|$SOCKS_PORT|g" "$SCRIPTS_DIR/tunnel-proxy.sh"
sed -i '' "s|SSH_KEY_PLACEHOLDER|$SSH_KEY_FILE|g" "$SCRIPTS_DIR/tunnel-proxy.sh"
sed -i '' "s|SSH_USER_PLACEHOLDER|$SSH_USER|g" "$SCRIPTS_DIR/tunnel-proxy.sh"
sed -i '' "s|SSH_SERVER_PLACEHOLDER|$SSH_SERVER|g" "$SCRIPTS_DIR/tunnel-proxy.sh"
chmod +x "$SCRIPTS_DIR/tunnel-proxy.sh"

cat > "$LAUNCH_AGENTS/tunnel-proxy.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>tunnel-proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPTS_DIR/tunnel-proxy.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>NetworkState</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$SCRIPTS_DIR/tunnel-proxy.log</string>
    <key>StandardErrorPath</key>
    <string>$SCRIPTS_DIR/tunnel-proxy.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

# Load/reload the service
if launchctl print "$DOMAIN_TARGET/tunnel-proxy" &>/dev/null; then
    launchctl bootout "$DOMAIN_TARGET/tunnel-proxy" 2>/dev/null || true
    sleep 1
fi
launchctl bootstrap "$DOMAIN_TARGET" "$LAUNCH_AGENTS/tunnel-proxy.plist"

echo "✅ SSH SOCKS proxy installed: socks5://127.0.0.1:$SOCKS_PORT"

# --- Optional: Xray VLESS+XHTTP+Reality tunnel ---
XRAY_ENABLED=""

if [ -n "$XRAY_UUID" ] && [ -n "$XRAY_PUBLIC_KEY" ] && [ -n "$XRAY_SHORT_ID" ]; then
    XRAY_ENABLED="reality"
    echo "📦 Installing Xray VLESS+XHTTP+Reality tunnel..."
fi

if [ -n "$XRAY_ENABLED" ]; then
    # Install xray-core if missing
    if ! command -v xray >/dev/null 2>&1; then
        echo "📦 Installing xray-core via Homebrew..."
        if ! command -v brew >/dev/null 2>&1; then
            echo "❌ Homebrew not found. Install it from https://brew.sh"
            exit 1
        fi
        brew install xray
    fi

    XRAY_BIN="$(command -v xray)"
    XRAY_CONFIG_DIR="$SCRIPTS_DIR/xray"
    XRAY_SNI="${XRAY_SNI:-www.google.com}"
    XRAY_SERVER_PORT="${XRAY_SERVER_PORT:-443}"
    XRAY_PATH="${XRAY_PATH:-/9f3a7c2b}"
    mkdir -p "$XRAY_CONFIG_DIR"

    cat > "$XRAY_CONFIG_DIR/config.json" << XRAY_EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": { "udp": true },
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
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$XRAY_SNI",
          "publicKey": "$XRAY_PUBLIC_KEY",
          "shortId": "$XRAY_SHORT_ID",
          "fingerprint": "chrome"
        },
        "xhttpSettings": {
          "path": "$XRAY_PATH",
          "extra": {
            "xmux": {
              "maxConcurrency": "16-32",
              "cMaxReuseTimes": "64-128"
            }
          }
        }
      },
      "tag": "proxy"
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
XRAY_EOF

    cat > "$LAUNCH_AGENTS/tunnel-xray.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>tunnel-xray</string>
    <key>ProgramArguments</key>
    <array>
        <string>$XRAY_BIN</string>
        <string>run</string>
        <string>-config</string>
        <string>$XRAY_CONFIG_DIR/config.json</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$SCRIPTS_DIR/tunnel-xray.log</string>
    <key>StandardErrorPath</key>
    <string>$SCRIPTS_DIR/tunnel-xray.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

    # Stop SSH tunnel (same port), start Xray as primary
    if launchctl print "$DOMAIN_TARGET/tunnel-proxy" &>/dev/null; then
        launchctl bootout "$DOMAIN_TARGET/tunnel-proxy" 2>/dev/null || true
        sleep 1
    fi

    if launchctl print "$DOMAIN_TARGET/tunnel-xray" &>/dev/null; then
        launchctl bootout "$DOMAIN_TARGET/tunnel-xray" 2>/dev/null || true
        sleep 1
    fi
    launchctl bootstrap "$DOMAIN_TARGET" "$LAUNCH_AGENTS/tunnel-xray.plist"

    echo "✅ Xray VLESS+XHTTP+Reality installed: socks5://127.0.0.1:$SOCKS_PORT"
    echo "   SSH tunnel stopped (available as fallback)"
fi

# --- Optional: HTTP Proxy (pproxy) ---
if [ -n "$HTTP_PORT" ]; then
    echo "📦 Installing HTTP proxy (pproxy)..."
    
    # Find pproxy in common locations
    find_pproxy() {
        command -v pproxy 2>/dev/null && return 0

        local user_base=""
        if command -v python3 >/dev/null 2>&1; then
            user_base="$(python3 -c 'import site; print(site.USER_BASE)' 2>/dev/null || true)"
        fi

        for p in \
            "$HOME/.local/bin/pproxy" \
            "${user_base:+$user_base/bin/pproxy}" \
            "/opt/homebrew/bin/pproxy" \
            "/usr/local/bin/pproxy"
        do
            [ -x "$p" ] && echo "$p" && return 0
        done
        return 1
    }

    PPROXY_PATH="$(find_pproxy || true)"

    ensure_uv() {
        if command -v uv >/dev/null 2>&1; then
            return 0
        fi

        echo "📦 uv not found; installing..."

        # Prefer Homebrew if available
        if command -v brew >/dev/null 2>&1; then
            brew install uv
        else
            # Fallback: official installer (installs into ~/.local/bin by default)
            curl -LsSf https://astral.sh/uv/install.sh | sh
        fi

        # Make sure this shell can see the installed binary immediately
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

        if ! command -v uv >/dev/null 2>&1; then
            echo "❌ uv installation failed or not on PATH"
            exit 1
        fi
    }
    
    if [ -z "$PPROXY_PATH" ]; then
        echo "📦 Installing pproxy with uv..."
        ensure_uv
        uv python install 3.13 >/dev/null 2>&1 || uv python install 3.12 >/dev/null 2>&1
        uv tool uninstall pproxy >/dev/null 2>&1 || true
        uv tool install --python 3.13 pproxy >/dev/null 2>&1 || uv tool install --python 3.12 pproxy >/dev/null 2>&1
        UV_TOOL_BIN="$(uv tool dir --bin)"
        PPROXY_PATH="$UV_TOOL_BIN/pproxy"
        if [ ! -x "$PPROXY_PATH" ]; then
            echo "❌ pproxy not found at: $PPROXY_PATH"
            exit 1
        fi
    fi
    
    if [ -z "$PPROXY_PATH" ] || [ ! -x "$PPROXY_PATH" ]; then
        echo "❌ Failed to find pproxy after installation"
        exit 1
    fi

    cat > "$SCRIPTS_DIR/pproxy.sh" << EOF
#!/bin/sh
exec $PPROXY_PATH -r socks://127.0.0.1:$SOCKS_PORT -l http://:$HTTP_PORT
EOF
    chmod +x "$SCRIPTS_DIR/pproxy.sh"

    cat > "$LAUNCH_AGENTS/pproxy.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>pproxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPTS_DIR/pproxy.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$SCRIPTS_DIR/pproxy.log</string>
    <key>StandardErrorPath</key>
    <string>$SCRIPTS_DIR/pproxy.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

    if launchctl print "$DOMAIN_TARGET/pproxy" &>/dev/null; then
        launchctl bootout "$DOMAIN_TARGET/pproxy" 2>/dev/null || true
        sleep 1
    fi
    launchctl bootstrap "$DOMAIN_TARGET" "$LAUNCH_AGENTS/pproxy.plist"
    
    echo "✅ HTTP proxy installed: http://127.0.0.1:$HTTP_PORT"
fi

echo ""
echo "🎉 Done! Your proxy tunnel will auto-start on boot."
echo ""
echo "Useful commands:"
if [ -n "$XRAY_ENABLED" ]; then
    echo "  Status:   launchctl print gui/\$(id -u)/tunnel-xray"
    echo "  Logs:     tail -f ~/scripts/tunnel-xray.log"
    echo "  Restart:  launchctl kickstart -k gui/\$(id -u)/tunnel-xray"
    echo ""
    echo "  Switch to SSH fallback:"
    echo "    launchctl bootout gui/\$(id -u)/tunnel-xray"
    echo "    launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/tunnel-proxy.plist"
else
    echo "  Status:   launchctl print gui/\$(id -u)/tunnel-proxy"
    echo "  Logs:     tail -f ~/scripts/tunnel-proxy.log"
    echo "  Restart:  launchctl kickstart -k gui/\$(id -u)/tunnel-proxy"
fi

