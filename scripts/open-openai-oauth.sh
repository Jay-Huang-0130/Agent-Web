#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -ne 0 ]]; then
    echo "OpenAI OAuth URL must be provided on standard input." >&2
    exit 64
fi

oauth_url=
IFS= read -r oauth_url || true
if [[ -z "$oauth_url" || ${#oauth_url} -gt 8192 || "$oauth_url" == *$'\r'* ]]; then
    echo "Invalid OpenAI OAuth URL." >&2
    exit 64
fi

case "$oauth_url" in
    https://auth.openai.com/*|https://chatgpt.com/*)
        ;;
    *)
        echo "Only official OpenAI HTTPS authorization URLs are allowed." >&2
        exit 64
        ;;
esac

if ! pgrep -u "$(id -u)" -x chromium >/dev/null 2>&1; then
    echo "Agent Web Chromium is not running." >&2
    exit 69
fi

export HOME=/var/lib/agent-web
export DISPLAY=:1
export XAUTHORITY=/run/agent-web/Xauthority
export XDG_RUNTIME_DIR=/run/agent-web/xdg

if ! timeout --signal=TERM 15s chromium \
    --user-data-dir=/var/lib/agent-web/profile \
    --ozone-platform=x11 \
    --new-tab \
    "$oauth_url" >/dev/null 2>&1; then
    echo "Could not open the OAuth page in Agent Web Chromium." >&2
    exit 70
fi

echo "OK"
