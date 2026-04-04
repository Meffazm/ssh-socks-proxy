#!/bin/bash
set -euo pipefail

# Switch AmneziaWG tunnel on router to a different VPS
# Usage: vpn-switch <dk|nl|kg>
#        vpn-switch status
#        vpn-switch list
#        vpn-switch stop

ROUTER=192.168.50.1
ROUTER_PORT=22
SOCKS="socks5h://$ROUTER:8090"
HTTP_PROXY_ADDR="127.0.0.1:8091"

ssh_cmd() {
    ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$ROUTER_PORT" \
        "admin@$ROUTER" "export PATH=/opt/bin:/opt/sbin:\$PATH; $1" 2>&1
}

do_status() {
    echo "--- Router tunnel ---"
    ssh_cmd "awg-manage status"
    echo ""
    echo "--- SOCKS5 test ---"
    IP=$(curl -x "$SOCKS" --connect-timeout 5 -s https://ifconfig.me/ip 2>&1)
    if [ -n "$IP" ] && [ "$IP" != *"curl"* ]; then
        echo "  SOCKS5 ($SOCKS): $IP"
    else
        echo "  SOCKS5: FAILED"
    fi
    echo ""
    echo "--- HTTP proxy test ---"
    IP=$(curl -x "http://$HTTP_PROXY_ADDR" --connect-timeout 5 -s \
        https://ifconfig.me/ip 2>&1)
    if [ -n "$IP" ] && [ "$IP" != *"curl"* ]; then
        echo "  HTTP ($HTTP_PROXY_ADDR): $IP"
    else
        echo "  HTTP proxy: FAILED"
    fi
}

do_switch() {
    local server="$1"
    echo "Switching to $server..."
    echo ""

    RESULT=$(ssh_cmd "awg-manage switch $server")
    echo "$RESULT"
    echo ""

    sleep 2

    echo "--- Verifying ---"
    IP=$(curl -x "$SOCKS" --connect-timeout 10 -s https://ifconfig.me/ip 2>&1)
    if [ -n "$IP" ] && [ "$IP" != *"curl"* ]; then
        echo "  SOCKS5: $IP"
    else
        echo "  SOCKS5: FAILED (tunnel may need more time)"
        sleep 3
        IP=$(curl -x "$SOCKS" --connect-timeout 10 -s \
            https://ifconfig.me/ip 2>&1)
        echo "  SOCKS5 retry: ${IP:-FAILED}"
    fi

    IP2=$(curl -x "http://$HTTP_PROXY_ADDR" --connect-timeout 10 -s \
        https://ifconfig.me/ip 2>&1)
    if [ -n "$IP2" ] && [ "$IP2" != *"curl"* ]; then
        echo "  HTTP:   $IP2"
    else
        echo "  HTTP proxy: FAILED"
    fi
    echo ""
    echo "Done."
}

do_list() {
    ssh_cmd "awg-manage list"
}

do_stop() {
    ssh_cmd "awg-manage stop"
    echo "Tunnel stopped."
}

case "${1:-}" in
    dk|nl|kg) do_switch "$1" ;;
    status)   do_status ;;
    list)     do_list ;;
    stop)     do_stop ;;
    *)
        echo "Usage: vpn <dk|nl|kg|status|list|stop>"
        echo ""
        do_list
        ;;
esac
