#!/usr/bin/env bash
set -Eeuo pipefail

: "${AGENT_WEB_WIDTH:=1280}"
: "${AGENT_WEB_HEIGHT:=720}"
: "${AGENT_WEB_DEPTH:=24}"
: "${AGENT_WEB_CACHE_SIZE:=536870912}"
: "${AGENT_WEB_LANG:=zh-TW}"

for numeric_value in \
    "$AGENT_WEB_WIDTH" \
    "$AGENT_WEB_HEIGHT" \
    "$AGENT_WEB_DEPTH" \
    "$AGENT_WEB_CACHE_SIZE"; do
    if [[ ! "$numeric_value" =~ ^[0-9]+$ ]]; then
        echo "Agent Web: invalid numeric setting: $numeric_value" >&2
        exit 64
    fi
done

rm -f "$XAUTHORITY"
xauth -f "$XAUTHORITY" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$(mcookie)"
chmod 600 "$XAUTHORITY"

vnc_pid=""
desktop_pid=""

cleanup() {
    trap - EXIT INT TERM HUP
    [[ -z "$desktop_pid" ]] || kill "$desktop_pid" 2>/dev/null || true
    [[ -z "$vnc_pid" ]] || kill "$vnc_pid" 2>/dev/null || true
    [[ -z "$desktop_pid" ]] || wait "$desktop_pid" 2>/dev/null || true
    [[ -z "$vnc_pid" ]] || wait "$vnc_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

/usr/bin/Xtigervnc "$DISPLAY" \
    -auth "$XAUTHORITY" \
    -geometry "${AGENT_WEB_WIDTH}x${AGENT_WEB_HEIGHT}" \
    -depth "$AGENT_WEB_DEPTH" \
    -rfbport 5901 \
    -localhost yes \
    -SecurityTypes None \
    -desktop "Agent Web Chromium" &
vnc_pid=$!

display_ready=0
for _ in $(seq 1 100); do
    if ! kill -0 "$vnc_pid" 2>/dev/null; then
        echo "Agent Web: Xtigervnc exited before the display became ready." >&2
        exit 1
    fi
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        display_ready=1
        break
    fi
    sleep 0.1
done

[[ "$display_ready" -eq 1 ]] || {
    echo "Agent Web: X display did not become ready." >&2
    exit 1
}

dbus-run-session -- bash -c '
    set -Eeuo pipefail
    openbox --sm-disable &
    wm_pid=$!

    if command -v tigervncconfig >/dev/null 2>&1; then
        tigervncconfig -iconic >/dev/null 2>&1 &
    fi

    while kill -0 "$wm_pid" 2>/dev/null; do
        set +e
        chromium \
            --user-data-dir=/data/profile \
            --disk-cache-dir=/cache \
            --disk-cache-size="$AGENT_WEB_CACHE_SIZE" \
            --ozone-platform=x11 \
            --password-store=basic \
            --lang="$AGENT_WEB_LANG" \
            --no-first-run \
            --no-default-browser-check \
            --disable-session-crashed-bubble \
            --start-maximized \
            --window-position=0,0 \
            --window-size="${AGENT_WEB_WIDTH},${AGENT_WEB_HEIGHT}" \
            about:newtab
        chromium_status=$?
        set -e

        kill -0 "$wm_pid" 2>/dev/null || exit 1
        echo "Agent Web: Chromium exited with status $chromium_status; restarting in 3 seconds." >&2
        sleep 3
    done
' &
desktop_pid=$!

exit_code=1
wait -n "$vnc_pid" "$desktop_pid" || exit_code=$?
exit "$exit_code"
