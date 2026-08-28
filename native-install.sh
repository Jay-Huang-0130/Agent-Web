#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install_root=$HOME/.local/share/agent-web
old_data_root=$install_root/data
old_config_file=$HOME/.config/agent-web/env
native_data_root=/var/lib/agent-web
native_cache_root=/var/cache/agent-web
native_config_root=/etc/agent-web
controller_file=/usr/local/bin/agent-webctl

update_only=0
reset_password=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [--update] [--reset-password]

Installs Agent Web directly on Debian as hardened systemd services.
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
    echo "Run this installer as your normal login user, not root." >&2
    exit 77
fi

if [[ ! -r /etc/os-release ]]; then
    echo "This installer supports Debian 13 (Trixie) on Raspberry Pi." >&2
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
    nginx/agent-web.conf
    policy/agent-web.json
    scripts/native-agent-webctl
    scripts/browser-session.sh
    systemd/agent-web.target
    systemd/agent-web-browser.service
    systemd/agent-web-novnc.service
    systemd/agent-web-web.service
)
for relative_file in "${required_project_files[@]}"; do
    [[ -f "$project_root/$relative_file" ]] || {
        echo "Project file is missing: $relative_file" >&2
        exit 66
    }
done

sudo -v

AGENT_WEB_USERNAME=browser
if [[ -r /etc/agent-web/controller.env ]]; then
    # shellcheck disable=SC1091
    source /etc/agent-web/controller.env
elif [[ -r "$old_config_file" ]]; then
    # shellcheck disable=SC1090
    source "$old_config_file"
fi
AGENT_WEB_SOURCE_DIR=$project_root

echo "Stopping and removing the previous Agent Web container, if present..."
systemctl --user disable --now agent-web.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/agent-web.service"
rm -rf --one-file-system "$HOME/.config/systemd/user/agent-web.service.d"
rm -f "$HOME/agent-web-debug.log"
systemctl --user daemon-reload 2>/dev/null || true
if command -v podman >/dev/null 2>&1; then
    podman rm --force --ignore agent-web agent-web-debug 2>/dev/null || true
    podman image rm localhost/agent-web:latest 2>/dev/null || true
fi

nginx_was_installed=0
if [[ $(dpkg-query -W -f='${Status}' nginx 2>/dev/null || true) == \
    "install ok installed" ]]; then
    nginx_was_installed=1
fi

host_packages=(
    apache2-utils
    ca-certificates
    chromium
    chromium-l10n
    chromium-sandbox
    curl
    dbus-x11
    fonts-wqy-zenhei
    libgl1-mesa-dri
    nginx
    novnc
    openbox
    openssl
    tigervnc-standalone-server
    tigervnc-tools
    websockify
    x11-utils
    xauth
    xdg-utils
)
missing_packages=()
for package_name in "${host_packages[@]}"; do
    if [[ $(dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null || true) != \
        "install ok installed" ]]; then
        missing_packages+=("$package_name")
    fi
done

if (("${#missing_packages[@]}" > 0)); then
    echo "Installing native browser packages: ${missing_packages[*]}"
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${missing_packages[@]}"
fi

if [[ $nginx_was_installed -eq 0 ]]; then
    sudo systemctl disable --now nginx.service 2>/dev/null || true
fi

if ! getent group agent-web >/dev/null; then
    sudo groupadd --system agent-web
fi
if ! id agent-web >/dev/null 2>&1; then
    sudo useradd \
        --system \
        --gid agent-web \
        --home-dir "$native_data_root" \
        --shell /usr/sbin/nologin \
        agent-web
fi

if ! getent group agent-web-web >/dev/null; then
    sudo groupadd --system agent-web-web
fi
if ! id agent-web-web >/dev/null 2>&1; then
    sudo useradd \
        --system \
        --gid agent-web-web \
        --home-dir /nonexistent \
        --shell /usr/sbin/nologin \
        agent-web-web
fi

sudo install -d -o agent-web -g agent-web -m 0700 \
    "$native_data_root" \
    "$native_data_root/profile" \
    "$native_data_root/downloads"
sudo install -d -o root -g root -m 0755 "$native_cache_root"
sudo install -d -o agent-web -g agent-web -m 0700 \
    "$native_cache_root/chromium"
sudo install -d -o agent-web-web -g agent-web-web -m 0700 \
    "$native_cache_root/nginx" \
    "$native_cache_root/nginx/client-body" \
    "$native_cache_root/nginx/proxy" \
    "$native_cache_root/nginx/fastcgi" \
    "$native_cache_root/nginx/uwsgi" \
    "$native_cache_root/nginx/scgi"
sudo install -d -o root -g root -m 0755 "$native_config_root"
sudo install -d -o root -g root -m 0755 \
    /usr/local/lib/agent-web \
    /etc/chromium/policies/managed

migrate_directory() {
    local source_dir=$1
    local destination_dir=$2

    if [[ -d "$source_dir" ]] &&
        [[ -n $(find "$source_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]] &&
        [[ -z $(sudo find "$destination_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
        echo "Migrating: $source_dir -> $destination_dir"
        sudo cp -a "$source_dir/." "$destination_dir/"
        sudo chown -R agent-web:agent-web "$destination_dir"
    fi
}

migrate_directory "$old_data_root/profile" "$native_data_root/profile"
migrate_directory "$old_data_root/downloads" "$native_data_root/downloads"

if [[ ! -s "$native_config_root/htpasswd" && -s "$old_data_root/state/htpasswd" ]]; then
    sudo install -o agent-web-web -g agent-web-web -m 0600 \
        "$old_data_root/state/htpasswd" \
        "$native_config_root/htpasswd"
fi
if [[ ! -s "$native_config_root/tls.crt" && -s "$old_data_root/state/tls.crt" ]]; then
    sudo install -o agent-web-web -g agent-web-web -m 0644 \
        "$old_data_root/state/tls.crt" \
        "$native_config_root/tls.crt"
fi
if [[ ! -s "$native_config_root/tls.key" && -s "$old_data_root/state/tls.key" ]]; then
    sudo install -o agent-web-web -g agent-web-web -m 0600 \
        "$old_data_root/state/tls.key" \
        "$native_config_root/tls.key"
fi

prompt_for_password() {
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        echo "A terminal is required to set the web password." >&2
        exit 74
    fi

    local entered_username first_password second_password password_tmp
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

    password_tmp=$(mktemp)
    trap 'rm -f -- "$password_tmp"' EXIT
    printf '%s\n' "$first_password" | htpasswd -niB "$AGENT_WEB_USERNAME" >"$password_tmp"
    sudo install -o agent-web-web -g agent-web-web -m 0600 \
        "$password_tmp" \
        "$native_config_root/htpasswd"
    rm -f -- "$password_tmp"
    trap - EXIT
    first_password=
    second_password=
}

if [[ $reset_password -eq 1 || ! -s "$native_config_root/htpasswd" ]]; then
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

generate_certificate() {
    local san certificate_tmp_dir
    certificate_tmp_dir=$(mktemp -d)
    trap 'rm -rf -- "$certificate_tmp_dir"' EXIT

    san="DNS:$host_name"
    if [[ "$host_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san="$san,IP:$host_ip"
    fi

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:3072 \
        -sha256 \
        -days 825 \
        -subj "/CN=$host_name" \
        -addext "subjectAltName=$san" \
        -keyout "$certificate_tmp_dir/tls.key" \
        -out "$certificate_tmp_dir/tls.crt"
    sudo install -o agent-web-web -g agent-web-web -m 0600 \
        "$certificate_tmp_dir/tls.key" \
        "$native_config_root/tls.key"
    sudo install -o agent-web-web -g agent-web-web -m 0644 \
        "$certificate_tmp_dir/tls.crt" \
        "$native_config_root/tls.crt"
    rm -rf -- "$certificate_tmp_dir"
    trap - EXIT
}

if [[ ! -s "$native_config_root/tls.crt" || ! -s "$native_config_root/tls.key" ]]; then
    generate_certificate
fi

browser_env_tmp=$(mktemp)
controller_env_tmp=$(mktemp)
trap 'rm -f -- "$browser_env_tmp" "$controller_env_tmp"' EXIT
{
    printf 'AGENT_WEB_WIDTH=1280\n'
    printf 'AGENT_WEB_HEIGHT=720\n'
    printf 'AGENT_WEB_DEPTH=24\n'
    printf 'AGENT_WEB_CACHE_SIZE=536870912\n'
    printf 'AGENT_WEB_LANG=zh-TW\n'
    printf 'AGENT_WEB_PROFILE_DIR=%q\n' "$native_data_root/profile"
    printf 'AGENT_WEB_DOWNLOAD_DIR=%q\n' "$native_data_root/downloads"
    printf 'AGENT_WEB_CACHE_DIR=%q\n' "$native_cache_root/chromium"
} >"$browser_env_tmp"
{
    printf 'AGENT_WEB_USERNAME=%q\n' "$AGENT_WEB_USERNAME"
    printf 'AGENT_WEB_HOSTNAME=%q\n' "$host_name"
    printf 'AGENT_WEB_HOST_IP=%q\n' "$host_ip"
    printf 'AGENT_WEB_SOURCE_DIR=%q\n' "$AGENT_WEB_SOURCE_DIR"
} >"$controller_env_tmp"

sudo install -o root -g agent-web -m 0640 \
    "$browser_env_tmp" \
    "$native_config_root/browser.env"
sudo install -o root -g root -m 0644 \
    "$controller_env_tmp" \
    "$native_config_root/controller.env"
rm -f -- "$browser_env_tmp" "$controller_env_tmp"
trap - EXIT

sudo install -o root -g root -m 0755 \
    "$project_root/scripts/browser-session.sh" \
    /usr/local/lib/agent-web/browser-session.sh
sudo install -o root -g root -m 0755 \
    "$project_root/scripts/native-agent-webctl" \
    "$controller_file"
install -d -m 0755 "$HOME/.local/bin"
install -m 0755 \
    "$project_root/scripts/native-agent-webctl" \
    "$HOME/.local/bin/agent-webctl"
sudo install -o root -g root -m 0644 \
    "$project_root/policy/agent-web.json" \
    /etc/chromium/policies/managed/agent-web.json
sudo install -o root -g root -m 0644 \
    "$project_root/nginx/agent-web.conf" \
    "$native_config_root/nginx.conf"
for unit_name in \
    agent-web.target \
    agent-web-browser.service \
    agent-web-novnc.service \
    agent-web-web.service; do
    sudo install -o root -g root -m 0644 \
        "$project_root/systemd/$unit_name" \
        "/etc/systemd/system/$unit_name"
done

sudo nginx -t -c "$native_config_root/nginx.conf"
sudo systemctl daemon-reload
sudo systemctl enable agent-web.target
sudo systemctl restart agent-web.target

echo "Waiting for Agent Web to become ready..."
healthy=0
for _ in $(seq 1 90); do
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:6901/ || true)
    if [[ "$http_code" == 401 ]]; then
        healthy=1
        break
    fi
    sleep 1
done

if [[ $healthy -ne 1 ]]; then
    echo "Agent Web did not become healthy. Recent logs:" >&2
    sudo journalctl \
        -u agent-web-browser.service \
        -u agent-web-novnc.service \
        -u agent-web-web.service \
        -n 120 \
        --no-pager >&2 || true
    exit 70
fi

if [[ -z "$host_ip" ]]; then
    access_url="https://$host_name:6901/"
else
    access_url="https://$host_ip:6901/"
fi

if [[ $update_only -eq 1 ]]; then
    echo "Agent Web native services were updated successfully."
else
    echo "Agent Web native services were installed successfully."
fi
echo "Open: $access_url"
echo "The first visit will show a private self-signed certificate warning."
echo "Manage it with: agent-webctl status|logs|restart|stop|start|set-password|update"
echo "The old Podman packages remain installed, but Agent Web no longer uses them."
