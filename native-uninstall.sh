#!/usr/bin/env bash
set -Eeuo pipefail

purge_data=0
case "${1:-}" in
    "")
        ;;
    --purge-data)
        purge_data=1
        ;;
    -h|--help)
        echo "Usage: ./uninstall.sh [--purge-data]"
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 64
        ;;
esac

if [[ $EUID -eq 0 ]]; then
    echo "Run this uninstaller as your normal login user, not root." >&2
    exit 77
fi

sudo systemctl disable --now agent-web.target 2>/dev/null || true
sudo rm -f \
    /etc/systemd/system/agent-web.target \
    /etc/systemd/system/agent-web-browser.service \
    /etc/systemd/system/agent-web-novnc.service \
    /etc/systemd/system/agent-web-oauth.socket \
    /etc/systemd/system/agent-web-oauth@.service \
    /etc/systemd/system/agent-web-web.service \
    /usr/local/lib/agent-web/browser-session.sh \
    /usr/local/lib/agent-web/open-openai-oauth \
    /usr/local/bin/agent-webctl \
    /etc/chromium/policies/managed/agent-web.json
rm -f "$HOME/.local/bin/agent-webctl"
sudo systemctl daemon-reload

if [[ $purge_data -eq 1 ]]; then
    data_root=$(realpath -m /var/lib/agent-web)
    cache_root=$(realpath -m /var/cache/agent-web)
    config_root=$(realpath -m /etc/agent-web)

    if [[ "$data_root" != /var/lib/agent-web || \
        "$cache_root" != /var/cache/agent-web || \
        "$config_root" != /etc/agent-web ]]; then
        echo "Safety check failed; refusing to remove data." >&2
        exit 78
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        echo "A terminal is required to purge browser data." >&2
        exit 74
    fi

    echo "This permanently removes cookies, logins, history, downloads, and TLS/auth data:"
    echo "  $data_root"
    echo "  $cache_root"
    echo "  $config_root"
    read -r -p 'Type DELETE AGENT WEB to continue: ' confirmation </dev/tty
    if [[ "$confirmation" != "DELETE AGENT WEB" ]]; then
        echo "Purge cancelled. Browser data was preserved."
        exit 1
    fi

    sudo rm -rf --one-file-system "$data_root"
    sudo rm -rf --one-file-system "$cache_root"
    sudo rm -rf --one-file-system "$config_root"
    sudo userdel agent-web-web 2>/dev/null || true
    sudo userdel agent-web 2>/dev/null || true
    echo "Agent Web and its native persistent data were removed."
else
    echo "Agent Web services were uninstalled."
    echo "Browser data was preserved in: /var/lib/agent-web"
    echo "Login and TLS settings were preserved in: /etc/agent-web"
    echo "To remove them permanently, run: ./uninstall.sh --purge-data"
fi

echo "Debian packages were left installed so unrelated host software is not affected."
