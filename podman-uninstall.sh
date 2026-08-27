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
    echo "Run this uninstaller as the normal Agent Web user, not root." >&2
    exit 77
fi

install_root=$(realpath -m "$HOME/.local/share/agent-web")
expected_root=$(realpath -m "$HOME/.local/share/agent-web")
unit_file=$HOME/.config/systemd/user/agent-web.service
config_dir=$HOME/.config/agent-web
controller_file=$HOME/.local/bin/agent-webctl

systemctl --user disable --now agent-web.service 2>/dev/null || true
podman rm --force --ignore agent-web 2>/dev/null || true
podman image rm localhost/agent-web:latest 2>/dev/null || true

rm -f "$unit_file" "$controller_file"
systemctl --user daemon-reload

if [[ $purge_data -eq 1 ]]; then
    if [[ -z "${HOME:-}" || "$HOME" == / || \
        "$install_root" != "$expected_root" || \
        "$install_root" != "$HOME/.local/share/agent-web" ]]; then
        echo "Safety check failed; refusing to remove data." >&2
        exit 78
    fi

    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        echo "A terminal is required to purge browser data." >&2
        exit 74
    fi

    echo "This permanently removes cookies, logins, history, downloads, and source code:"
    echo "  $install_root"
    read -r -p 'Type DELETE AGENT WEB to continue: ' confirmation </dev/tty
    if [[ "$confirmation" != "DELETE AGENT WEB" ]]; then
        echo "Purge cancelled. Browser data was preserved."
        exit 1
    fi

    rm -rf --one-file-system "$install_root"
    rm -rf --one-file-system "$config_dir"
    echo "Agent Web and all persistent browser data were removed."
else
    echo "Agent Web was uninstalled."
    echo "Browser data and source were preserved in: $install_root"
    echo "Login settings were preserved in: $config_dir"
    echo "To remove them permanently, run: ./uninstall.sh --purge-data"
fi

echo "Podman packages and login linger were left installed for safety."
