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
if [ -z "$SSH_SERVER" ]; then
    echo "❌ SSH_SERVER must be set in .env"
    exit 1
fi
if [ -z "$XRAY_UUID" ] || [ -z "$XRAY_PUBLIC_KEY" ] || [ -z "$XRAY_SHORT_ID" ]; then
    echo "❌ XRAY_UUID, XRAY_PUBLIC_KEY, and XRAY_SHORT_ID must be set in .env"
    exit 1
fi

SOCKS_PORT="${SOCKS_PORT:-8090}"
XRAY_SNI="${XRAY_SNI:-dl.google.com}"
XRAY_SERVER_PORT="${XRAY_SERVER_PORT:-443}"

SCRIPTS_DIR="$HOME/scripts"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DOMAIN_TARGET="gui/$(id -u)"

mkdir -p "$SCRIPTS_DIR" "$LAUNCH_AGENTS"

# --- Xray VLESS+Reality tunnel ---
echo "📦 Installing Xray VLESS+Reality tunnel..."

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
mkdir -p "$XRAY_CONFIG_DIR"

cat > "$XRAY_CONFIG_DIR/config.json" << XRAY_EOF
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
        },
        "sockopt": {
          "tcpKeepAliveIdle": 100,
          "tcpNoDelay": true,
          "fragment": {
            "packets": "tlshello",
            "length": "100-200",
            "interval": "10-20"
          }
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

if launchctl print "$DOMAIN_TARGET/tunnel-xray" &>/dev/null; then
    launchctl bootout "$DOMAIN_TARGET/tunnel-xray" 2>/dev/null || true
    sleep 1
fi
launchctl bootstrap "$DOMAIN_TARGET" "$LAUNCH_AGENTS/tunnel-xray.plist"

echo "✅ Xray VLESS+Reality installed: socks5://127.0.0.1:$SOCKS_PORT"

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
echo "  Status:   launchctl print gui/\$(id -u)/tunnel-xray"
echo "  Logs:     tail -f ~/scripts/tunnel-xray.log"
echo "  Restart:  launchctl kickstart -k gui/\$(id -u)/tunnel-xray"

