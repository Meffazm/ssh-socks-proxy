#!/bin/bash
set -euo pipefail

# Install pproxy as HTTP-to-SOCKS5 converter (macOS)
# Converts router's SOCKS5 proxy to HTTP for apps that don't support SOCKS
# (e.g., Claude Code, Docker Desktop, npm, pip)

ROUTER=192.168.50.1
SOCKS_PORT=8090
HTTP_PORT=8091
SCRIPTS_DIR="$HOME/scripts"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "Setting up HTTP proxy (pproxy) on macOS..."

# Find or install pproxy
find_pproxy() {
    command -v pproxy 2>/dev/null && return 0
    local user_base=""
    if command -v python3 >/dev/null 2>&1; then
        user_base="$(python3 -c 'import site; print(site.USER_BASE)' \
            2>/dev/null || true)"
    fi
    for p in \
        "$HOME/.local/bin/pproxy" \
        "${user_base:+$user_base/bin/pproxy}" \
        "/opt/homebrew/bin/pproxy" \
        "/usr/local/bin/pproxy"; do
        [ -x "$p" ] && echo "$p" && return 0
    done
    return 1
}

PPROXY_PATH="$(find_pproxy || true)"

if [ -z "$PPROXY_PATH" ]; then
    echo "Installing pproxy..."
    if command -v uv >/dev/null 2>&1; then
        uv tool install pproxy >/dev/null 2>&1
        UV_BIN="$(uv tool dir --bin)"
        PPROXY_PATH="$UV_BIN/pproxy"
    elif command -v pip3 >/dev/null 2>&1; then
        pip3 install --user pproxy >/dev/null 2>&1
        PPROXY_PATH="$(find_pproxy)"
    else
        echo "Error: need uv or pip3 to install pproxy"
        exit 1
    fi
fi

echo "pproxy found: $PPROXY_PATH"

mkdir -p "$SCRIPTS_DIR" "$LAUNCH_AGENTS"

# Create launcher script
cat > "$SCRIPTS_DIR/pproxy.sh" << EOF
#!/bin/sh
exec $PPROXY_PATH -r socks5://$ROUTER:$SOCKS_PORT -l http://:$HTTP_PORT
EOF
chmod +x "$SCRIPTS_DIR/pproxy.sh"

# Create launchd plist
cat > "$LAUNCH_AGENTS/pproxy.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
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

DOMAIN_TARGET="gui/$(id -u)"
if launchctl print "$DOMAIN_TARGET/pproxy" &>/dev/null; then
    launchctl bootout "$DOMAIN_TARGET/pproxy" 2>/dev/null || true
    sleep 1
fi
launchctl bootstrap "$DOMAIN_TARGET" "$LAUNCH_AGENTS/pproxy.plist"

echo ""
echo "HTTP proxy installed: http://127.0.0.1:$HTTP_PORT"
echo "  Forwards to: socks5://$ROUTER:$SOCKS_PORT (router)"
echo ""
echo "Add to your shell profile:"
echo "  export HTTP_PROXY=\"http://127.0.0.1:$HTTP_PORT\""
echo "  export HTTPS_PROXY=\"http://127.0.0.1:$HTTP_PORT\""
echo "  export NO_PROXY=\"localhost,127.0.0.1,192.168.50.0/24\""
