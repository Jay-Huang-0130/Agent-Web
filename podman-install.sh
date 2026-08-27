#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install_root=$HOME/.local/share/agent-web
data_root=$install_root/data
state_dir=$data_root/state
config_dir=$HOME/.config/agent-web
config_file=$config_dir/env
unit_dir=$HOME/.config/systemd/user
unit_file=$unit_dir/agent-web.service
controller_file=$HOME/.local/bin/agent-webctl
image_name=localhost/agent-web:latest

update_only=0
reset_password=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [--update] [--reset-password]

Installs Agent Web as a rootless Podman container and a systemd user service.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)
            update_only=1
            ;;
        --reset-password)
            reset_password=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this installer as root or with sudo." >&2
    echo "Run it as the normal user that will own the browser profile." >&2
    exit 77
fi

if [[ ! -r /etc/os-release ]]; then
    echo "This installer supports Debian 13 (Trixie) on Raspberry Pi OS." >&2
    exit 69
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != debian || "${VERSION_CODENAME:-}" != trixie ]]; then
    echo "Unsupported OS: expected Debian 13 (Trixie), found ${PRETTY_NAME:-unknown}." >&2
    exit 69
fi

if [[ $(dpkg --print-architecture) != arm64 ]]; then
    echo "Unsupported architecture: expected arm64." >&2
    exit 69
fi

required_project_files=(
    Containerfile
    container/browser-session.sh
    container/entrypoint.sh
    container/nginx.conf
    container/policy.json
    scripts/agent-webctl
    systemd/agent-web.service.in
)
for relative_file in "${required_project_files[@]}"; do
    if [[ ! -f "$project_root/$relative_file" ]]; then
        echo "Project file is missing: $relative_file" >&2
        exit 66
    fi
done

host_packages=(
    ca-certificates
    curl
    dbus-user-session
    fuse-overlayfs
    git
    passt
    podman
    slirp4netns
    uidmap
)
missing_packages=()
for package_name in "${host_packages[@]}"; do
    if [[ $(dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null || true) != \
        "install ok installed" ]]; then
        missing_packages+=("$package_name")
    fi
done

if (("${#missing_packages[@]}" > 0)); then
    echo "Installing host packages: ${missing_packages[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing_packages[@]}"
fi

if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null; then
    echo "Creating subordinate UID range for rootless Podman..."
    sudo usermod --add-subuids 100000-165535 "$USER"
fi
if ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
    echo "Creating subordinate GID range for rootless Podman..."
    sudo usermod --add-subgids 100000-165535 "$USER"
fi

sudo loginctl enable-linger "$USER"
podman system migrate >/dev/null 2>&1 || true

install -d -m 0700 \
    "$install_root" \
    "$data_root" \
    "$data_root/profile" \
    "$data_root/downloads" \
    "$state_dir" \
    "$config_dir" \
    "$unit_dir" \
    "$HOME/.local/bin"

AGENT_WEB_USERNAME=browser
AGENT_WEB_SOURCE_DIR=$project_root
if [[ -r "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
fi
AGENT_WEB_SOURCE_DIR=$project_root

prompt_for_password() {
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        echo "A terminal is required to set the web password." >&2
        exit 74
    fi

    local first_password second_password
    while true; do
        read -r -p "Web login name [${AGENT_WEB_USERNAME}]: " entered_username </dev/tty
        entered_username=${entered_username:-$AGENT_WEB_USERNAME}
        if [[ "$entered_username" =~ ^[A-Za-z0-9._-]+$ ]]; then
            AGENT_WEB_USERNAME=$entered_username
            break
        fi
        echo "Use only letters, numbers, dot, underscore, or dash." >/dev/tty
    done

    while true; do
        read -r -s -p "New web password (at least 12 characters): " first_password </dev/tty
        printf '\n' >/dev/tty
        read -r -s -p "Confirm web password: " second_password </dev/tty
        printf '\n' >/dev/tty

        if [[ "${#first_password}" -lt 12 ]]; then
            echo "The password must contain at least 12 characters." >/dev/tty
        elif [[ "$first_password" != "$second_password" ]]; then
            echo "The passwords do not match." >/dev/tty
        elif [[ "$first_password" == *$'\n'* || "$first_password" == *$'\r'* ]]; then
            echo "The password cannot contain a newline." >/dev/tty
        else
            break
        fi
    done

    systemctl --user stop agent-web.service 2>/dev/null || true
    rm -f "$state_dir/htpasswd"
    printf '%s\n' "$first_password" >"$state_dir/password.init"
    chmod 600 "$state_dir/password.init"
    first_password=
    second_password=
}

if [[ $reset_password -eq 1 || ! -s "$state_dir/htpasswd" ]]; then
    prompt_for_password
fi

host_name=$(hostname -s)
if [[ ! "$host_name" =~ ^[A-Za-z0-9.-]+$ ]]; then
    host_name=agent-web
fi
host_ip=$(
    ip -4 -o address show scope global |
        awk '{ split($4, address, "/"); print address[1]; exit }'
)

config_tmp=$config_file.tmp
{
    printf 'AGENT_WEB_USERNAME=%q\n' "$AGENT_WEB_USERNAME"
    printf 'AGENT_WEB_HOSTNAME=%q\n' "$host_name"
    printf 'AGENT_WEB_HOST_IP=%q\n' "$host_ip"
    printf 'AGENT_WEB_SOURCE_DIR=%q\n' "$AGENT_WEB_SOURCE_DIR"
} >"$config_tmp"
chmod 600 "$config_tmp"
mv "$config_tmp" "$config_file"

echo "Building the isolated Chromium image. This can take several minutes..."
podman build \
    --pull=always \
    --format docker \
    --tag "$image_name" \
    --build-arg "BROWSER_UID=$(id -u)" \
    --build-arg "BROWSER_GID=$(id -g)" \
    "$project_root"

sed \
    -e "s/__HOST_UID__/$(id -u)/g" \
    -e "s/__HOST_GID__/$(id -g)/g" \
    -e "s/__WEB_USERNAME__/$AGENT_WEB_USERNAME/g" \
    -e "s/__HOST_NAME__/$host_name/g" \
    -e "s/__HOST_IP__/$host_ip/g" \
    "$project_root/systemd/agent-web.service.in" >"$unit_file.tmp"
chmod 600 "$unit_file.tmp"
mv "$unit_file.tmp" "$unit_file"

install -m 0755 "$project_root/scripts/agent-webctl" "$controller_file"

systemctl --user daemon-reload
systemctl --user enable --now agent-web.service

echo "Waiting for Agent Web to become ready..."
healthy=0
for _ in $(seq 1 60); do
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:6901/ || true)
    if [[ "$http_code" == 401 ]]; then
        healthy=1
        break
    fi
    sleep 1
done

if [[ $healthy -ne 1 ]]; then
    echo "Agent Web did not become healthy. Recent logs:" >&2
    journalctl --user -u agent-web.service -n 80 --no-pager >&2 || true
    exit 70
fi

if [[ -e "$state_dir/password.init" ]]; then
    echo "The container did not consume the temporary password file." >&2
    exit 70
fi

if [[ -z "$host_ip" ]]; then
    access_url="https://$host_name:6901/"
else
    access_url="https://$host_ip:6901/"
fi

if [[ $update_only -eq 1 ]]; then
    echo "Agent Web was updated successfully."
else
    echo "Agent Web was installed successfully."
fi
echo "Open: $access_url"
echo "Your browser will warn about the private self-signed certificate once."
echo "Manage it with: agent-webctl status|logs|restart|stop|start|set-password|update"
