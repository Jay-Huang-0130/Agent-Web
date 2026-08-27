#!/usr/bin/env bash
set -Eeuo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$project_root"

required_files=(
    .gitattributes
    Containerfile
    README.md
    bootstrap.sh
    install.sh
    podman-install.sh
    uninstall.sh
    podman-uninstall.sh
    validate.sh
    podman-validate.sh
    container/browser-session.sh
    container/entrypoint.sh
    container/nginx.conf
    container/policy.json
    scripts/agent-webctl
    systemd/agent-web.service.in
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
    podman-install.sh
    uninstall.sh
    podman-uninstall.sh
    validate.sh
    podman-validate.sh
    container/browser-session.sh
    container/entrypoint.sh
    scripts/agent-webctl
)

for shell_file in "${shell_files[@]}"; do
    bash -n "$shell_file"
    if LC_ALL=C grep -q $'\r' "$shell_file"; then
        echo "CRLF line endings are not allowed: $shell_file" >&2
        exit 1
    fi
done

if command -v python3 >/dev/null 2>&1 &&
    python3 -m json.tool container/policy.json >/dev/null 2>&1; then
    :
elif command -v jq >/dev/null 2>&1; then
    jq empty container/policy.json
else
    echo "Notice: skipped JSON parsing because python3 and jq are unavailable."
fi

for placeholder in \
    __HOST_UID__ \
    __HOST_GID__ \
    __WEB_USERNAME__ \
    __HOST_NAME__ \
    __HOST_IP__; do
    grep -q "$placeholder" systemd/agent-web.service.in || {
        echo "Missing systemd template placeholder: $placeholder" >&2
        exit 1
    }
done

grep -q '^USER browser$' Containerfile
grep -q -- '--userns=keep-id' systemd/agent-web.service.in
grep -q -- '--cap-drop=all' systemd/agent-web.service.in
grep -q -- '--format docker' podman-install.sh
grep -q '127.0.0.1:6080' container/nginx.conf
grep -q '127.0.0.1:5901' container/entrypoint.sh
grep -q 'client_body_temp_path /tmp/agent-web-nginx/' container/nginx.conf
grep -q 'nginx_temp_dir=/tmp/agent-web-nginx' container/entrypoint.sh

if grep -E -- '--tmpfs .*[,](uid|gid)=' systemd/agent-web.service.in; then
    echo "Podman --tmpfs must not use unsupported uid/gid mount options." >&2
    exit 1
fi

if grep -R -n -- '--no-sandbox' Containerfile container scripts systemd; then
    echo "Chromium sandbox must not be disabled." >&2
    exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${shell_files[@]}"
else
    echo "Notice: shellcheck is not installed; Bash syntax was still checked."
fi

echo "Agent Web project validation passed."
