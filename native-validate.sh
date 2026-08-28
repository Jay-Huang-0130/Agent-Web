#!/usr/bin/env bash
set -Eeuo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$project_root"

required_files=(
    .gitattributes
    README.md
    docs/AGENT-INTEGRATION.md
    docs/ARCHITECTURE.md
    docs/TROUBLESHOOTING.md
    docs/USER-GUIDE.md
    bootstrap.sh
    install.sh
    native-install.sh
    uninstall.sh
    native-uninstall.sh
    validate.sh
    native-validate.sh
    nginx/agent-web.conf
    policy/agent-web.json
    scripts/browser-session.sh
    scripts/native-agent-webctl
    systemd/agent-web.target
    systemd/agent-web-browser.service
    systemd/agent-web-novnc.service
    systemd/agent-web-web.service
)

for required_file in "${required_files[@]}"; do
    [[ -f "$required_file" ]] || {
        echo "Missing required file: $required_file" >&2
        exit 1
    }
done

shell_files=(
    bootstrap.sh
    install.sh
    native-install.sh
    uninstall.sh
    native-uninstall.sh
    validate.sh
    native-validate.sh
    scripts/browser-session.sh
    scripts/native-agent-webctl
)

for shell_file in "${shell_files[@]}"; do
    bash -n "$shell_file"
    if LC_ALL=C grep -q $'\r' "$shell_file"; then
        echo "CRLF line endings are not allowed: $shell_file" >&2
        exit 1
    fi
done

if command -v python3 >/dev/null 2>&1 &&
    python3 -m json.tool policy/agent-web.json >/dev/null 2>&1; then
    :
elif command -v jq >/dev/null 2>&1; then
    jq empty policy/agent-web.json
else
    echo "Notice: skipped JSON parsing because python3 and jq are unavailable."
fi

grep -q '^User=agent-web$' systemd/agent-web-browser.service
grep -q '^User=agent-web$' systemd/agent-web-novnc.service
grep -q '^User=agent-web-web$' systemd/agent-web-web.service
grep -q '127.0.0.1:6080 127.0.0.1:5901' systemd/agent-web-novnc.service
grep -q 'listen 0.0.0.0:6901 ssl;' nginx/agent-web.conf
grep -q '^error_log stderr info;$' nginx/agent-web.conf
grep -q 'auth_basic_user_file /etc/agent-web/htpasswd;' nginx/agent-web.conf
grep -q 'install -d -o agent-web-web -g agent-web-web -m 0700 /run/agent-web-web' native-install.sh
grep -q '6901/vnc.html' native-install.sh
grep -q '^AGENT_WEB_INFO_VERSION=1$' scripts/native-agent-webctl
grep -q '"DownloadDirectory": "/var/lib/agent-web/downloads"' policy/agent-web.json

if grep -R -n -- '--no-sandbox' \
    native-install.sh \
    scripts/browser-session.sh \
    systemd \
    nginx \
    policy; then
    echo "Chromium sandbox must not be disabled." >&2
    exit 1
fi

if grep -R -n -E 'podman (build|run)|Containerfile' \
    native-install.sh \
    scripts/browser-session.sh \
    systemd \
    nginx \
    policy; then
    echo "Native runtime files must not invoke a container runtime." >&2
    exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${shell_files[@]}"
else
    echo "Notice: shellcheck is not installed; Bash syntax was still checked."
fi

echo "Agent Web native project validation passed."
