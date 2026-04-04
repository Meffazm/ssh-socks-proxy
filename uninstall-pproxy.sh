#!/bin/bash
set -euo pipefail

# Uninstall local pproxy HTTP proxy (macOS)

DOMAIN_TARGET="gui/$(id -u)"

echo "Uninstalling pproxy..."

launchctl bootout "$DOMAIN_TARGET/pproxy" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/pproxy.plist
rm -f ~/scripts/pproxy.sh
rm -f ~/scripts/pproxy.log

echo "Done."
echo ""
echo "Remove these lines from ~/.zshrc if no longer needed:"
echo "  export HTTP_PROXY=..."
echo "  export HTTPS_PROXY=..."
echo "  export NO_PROXY=..."
