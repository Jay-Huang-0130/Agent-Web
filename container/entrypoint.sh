#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${AGENT_WEB_USERNAME:=browser}"
: "${AGENT_WEB_HOSTNAME:=agent-web.local}"
: "${AGENT_WEB_HOST_IP:=}"

state_dir=/state
password_file=$state_dir/password.init
auth_file=$state_dir/htpasswd
cert_file=$state_dir/tls.crt
key_file=$state_dir/tls.key

mkdir -p /run/agent-web/xdg /cache /data/profile /data/downloads "$state_dir"
chmod 700 /run/agent-web /run/agent-web/xdg /cache /data/profile /data/downloads "$state_dir"

if [[ ! "$AGENT_WEB_USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Agent Web: invalid web username." >&2
    exit 64
fi

if [[ ! "$AGENT_WEB_HOSTNAME" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Agent Web: invalid hostname." >&2
    exit 64
fi

if [[ ! -s "$auth_file" ]]; then
    [[ -r "$password_file" ]] || {
        echo "Agent Web: initial password file is missing." >&2
        exit 78
    }

    IFS= read -r initial_password <"$password_file" || true
    if [[ "${#initial_password}" -lt 12 ]]; then
        echo "Agent Web: initial password must contain at least 12 characters." >&2
        exit 64
    fi

    printf '%s\n' "$initial_password" |
        htpasswd -niB "$AGENT_WEB_USERNAME" >"$auth_file.tmp"
    mv "$auth_file.tmp" "$auth_file"
    chmod 600 "$auth_file"
    initial_password=""
    rm -f "$password_file"
fi

if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
    san="DNS:$AGENT_WEB_HOSTNAME"
    if [[ "$AGENT_WEB_HOST_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san="$san,IP:$AGENT_WEB_HOST_IP"
    fi

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:3072 \
        -sha256 \
        -days 825 \
        -subj "/CN=$AGENT_WEB_HOSTNAME" \
        -addext "subjectAltName=$san" \
        -keyout "$key_file.tmp" \
        -out "$cert_file.tmp"
    mv "$key_file.tmp" "$key_file"
    mv "$cert_file.tmp" "$cert_file"
    chmod 600 "$key_file"
    chmod 644 "$cert_file"
fi

nginx -t -c /etc/agent-web/nginx.conf

browser_pid=""
novnc_pid=""
nginx_pid=""

cleanup() {
    trap - EXIT INT TERM HUP
    [[ -z "$nginx_pid" ]] || kill "$nginx_pid" 2>/dev/null || true
    [[ -z "$novnc_pid" ]] || kill "$novnc_pid" 2>/dev/null || true
    [[ -z "$browser_pid" ]] || kill "$browser_pid" 2>/dev/null || true
    [[ -z "$nginx_pid" ]] || wait "$nginx_pid" 2>/dev/null || true
    [[ -z "$novnc_pid" ]] || wait "$novnc_pid" 2>/dev/null || true
    [[ -z "$browser_pid" ]] || wait "$browser_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

/usr/local/bin/agent-web-browser-session &
browser_pid=$!

/usr/bin/websockify \
    --web=/usr/share/novnc \
    127.0.0.1:6080 \
    127.0.0.1:5901 &
novnc_pid=$!

nginx -c /etc/agent-web/nginx.conf -g 'daemon off;' &
nginx_pid=$!

exit_code=1
wait -n "$browser_pid" "$novnc_pid" "$nginx_pid" || exit_code=$?
echo "Agent Web: a required process stopped; the container will restart." >&2
exit "$exit_code"
