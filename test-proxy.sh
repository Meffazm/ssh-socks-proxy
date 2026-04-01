#!/bin/bash
set -uo pipefail

OUT="$HOME/proxy-test-results.txt"
PROXY="socks5h://127.0.0.1:8090"
PASS=0
FAIL=0
WARN=0

log() { echo "$1" | tee -a "$OUT"; }
pass() { PASS=$((PASS + 1)); log "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL: $1"; }
warn() { WARN=$((WARN + 1)); log "  WARN: $1"; }

: > "$OUT"
log "=== Proxy test $(date) ==="
log "=== Run with Amnezia OFF ==="
log ""

# --- 1. Basic connectivity (no proxy) ---
log "[1] Direct internet (no proxy)"
if curl --connect-timeout 5 -s -o /dev/null https://ya.ru; then
    pass "Direct HTTPS works"
else
    warn "Direct HTTPS to ya.ru failed (may be normal if all traffic is proxied)"
fi

# --- 2. Proxy is listening ---
log ""
log "[2] Proxy listener"
if nc -z 127.0.0.1 8090 2>/dev/null; then
    pass "Port 8090 is open"
else
    fail "Port 8090 is NOT open — xray not running?"
    log ""; log "ABORTED: proxy not running"; cat "$OUT"; exit 1
fi

# --- 3. Single request through proxy ---
log ""
log "[3] Single request via proxy"
BODY=$(curl -x "$PROXY" --connect-timeout 10 -s https://ifconfig.me 2>&1)
if [ $? -eq 0 ] && [ -n "$BODY" ]; then
    pass "ifconfig.me returned: $BODY"
else
    fail "ifconfig.me failed: $BODY"
fi

# --- 4. Multiple sites sequentially ---
log ""
log "[4] Multiple sites (sequential)"
for site in https://www.google.com https://api.telegram.org https://github.com https://httpbin.org/get https://example.com; do
    CODE=$(curl -x "$PROXY" --connect-timeout 10 -s -o /dev/null -w "%{http_code}" "$site" 2>&1)
    if [ "$CODE" -ge 200 ] && [ "$CODE" -lt 400 ] 2>/dev/null; then
        pass "$site -> HTTP $CODE"
    else
        fail "$site -> $CODE"
    fi
done

# --- 5. Download >16KB (ТСПУ throttle detection) ---
log ""
log "[5] Large download (>16KB, detects ТСПУ throttle)"
TMPFILE=$(mktemp)
SIZE=$(curl -x "$PROXY" --connect-timeout 15 -s -o "$TMPFILE" -w "%{size_download}" \
    https://httpbin.org/bytes/102400 2>&1)
EXIT=$?
if [ $EXIT -eq 0 ] && [ "${SIZE:-0}" -ge 100000 ] 2>/dev/null; then
    pass "Downloaded ${SIZE} bytes (100KB) — no throttle"
elif [ "${SIZE:-0}" -gt 0 ] 2>/dev/null; then
    fail "Only ${SIZE} bytes received (expected 100KB) — possible ТСПУ 16KB throttle"
else
    fail "Download failed (exit: $EXIT)"
fi
rm -f "$TMPFILE"

# --- 6. Concurrent connections (browser simulation) ---
log ""
log "[6] Concurrent connections (10 parallel requests)"
TMPDIR=$(mktemp -d)
for i in $(seq 1 10); do
    (
        CODE=$(curl -x "$PROXY" --connect-timeout 10 -s -o /dev/null \
            -w "%{http_code}" "https://httpbin.org/delay/1?n=$i" 2>&1)
        echo "$i:$CODE" > "$TMPDIR/$i"
    ) &
done
wait

CONC_OK=0
CONC_FAIL=0
for i in $(seq 1 10); do
    RESULT=$(cat "$TMPDIR/$i" 2>/dev/null)
    CODE="${RESULT#*:}"
    if [ "$CODE" = "200" ]; then
        CONC_OK=$((CONC_OK + 1))
    else
        CONC_FAIL=$((CONC_FAIL + 1))
    fi
done
rm -rf "$TMPDIR"

if [ $CONC_FAIL -eq 0 ]; then
    pass "All 10/10 concurrent requests succeeded"
elif [ $CONC_OK -ge 7 ]; then
    warn "$CONC_OK/10 succeeded, $CONC_FAIL/10 failed (partial)"
else
    fail "Only $CONC_OK/10 succeeded — proxy breaks under concurrent load"
fi

# --- 7. Sustained rapid requests ---
log ""
log "[7] Sustained requests (20 rapid sequential)"
RAPID_OK=0
RAPID_FAIL=0
for i in $(seq 1 20); do
    CODE=$(curl -x "$PROXY" --connect-timeout 5 -s -o /dev/null \
        -w "%{http_code}" "https://httpbin.org/status/200" 2>&1)
    if [ "$CODE" = "200" ]; then
        RAPID_OK=$((RAPID_OK + 1))
    else
        RAPID_FAIL=$((RAPID_FAIL + 1))
    fi
done
if [ $RAPID_FAIL -eq 0 ]; then
    pass "All 20/20 rapid requests succeeded"
elif [ $RAPID_OK -ge 15 ]; then
    warn "$RAPID_OK/20 succeeded — some drops under sustained load"
else
    fail "Only $RAPID_OK/20 succeeded — proxy unreliable"
fi

# --- 8. Latency check ---
log ""
log "[8] Latency"
TIMES=$(curl -x "$PROXY" --connect-timeout 10 -s -o /dev/null \
    -w "connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s" \
    https://httpbin.org/get 2>&1)
log "  $TIMES"

# --- 9. Xray error log check ---
log ""
log "[9] Xray errors (last 2 minutes)"
ERRORS=$(grep -i "error\|fail" ~/scripts/tunnel-xray.log 2>/dev/null \
    | awk -v cutoff="$(date -v-2M '+%Y/%m/%d %H:%M' 2>/dev/null || date -d '2 minutes ago' '+%Y/%m/%d %H:%M' 2>/dev/null)" \
    '$0 >= cutoff' | tail -10)
if [ -z "$ERRORS" ]; then
    pass "No errors in Xray log"
else
    fail "Errors found in Xray log:"
    echo "$ERRORS" | while IFS= read -r line; do
        log "    $line"
    done
fi

# --- Summary ---
log ""
log "=============================="
log "PASS: $PASS  FAIL: $FAIL  WARN: $WARN"
if [ $FAIL -eq 0 ]; then
    log "RESULT: ALL GOOD"
else
    log "RESULT: BROKEN — $FAIL test(s) failed"
fi
log "=============================="
log ""
log "Results saved to $OUT"
