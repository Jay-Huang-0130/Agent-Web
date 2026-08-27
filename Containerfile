FROM docker.io/library/debian:trixie-slim

ARG BROWSER_UID=1000
ARG BROWSER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        apache2-utils \
        ca-certificates \
        chromium \
        chromium-common \
        chromium-l10n \
        chromium-sandbox \
        curl \
        dbus-x11 \
        dumb-init \
        fonts-noto-cjk \
        libgl1-mesa-dri \
        nginx \
        novnc \
        openbox \
        openssl \
        tigervnc-standalone-server \
        tigervnc-tools \
        websockify \
        x11-utils \
        xauth \
        xdg-utils \
    && rm -f /usr/sbin/policy-rc.d \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "$BROWSER_GID" browser \
    && useradd \
        --uid "$BROWSER_UID" \
        --gid "$BROWSER_GID" \
        --create-home \
        --shell /usr/sbin/nologin \
        browser \
    && install -d -m 0700 -o browser -g browser \
        /data/profile \
        /data/downloads \
        /state \
        /cache

COPY container/nginx.conf /etc/agent-web/nginx.conf
COPY container/policy.json /etc/chromium/policies/managed/agent-web.json
COPY --chmod=0755 container/entrypoint.sh /usr/local/bin/agent-web-entrypoint
COPY --chmod=0755 container/browser-session.sh /usr/local/bin/agent-web-browser-session

RUN chown browser:browser /state /cache /data/profile /data/downloads

ENV HOME=/home/browser \
    DISPLAY=:1 \
    XAUTHORITY=/run/agent-web/Xauthority \
    XDG_RUNTIME_DIR=/run/agent-web/xdg

USER browser
WORKDIR /home/browser

EXPOSE 6901

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD test "$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:6901/)" = "401" || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/agent-web-entrypoint"]
