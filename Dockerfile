# ===============================
#   UBUNTU + noVNC + Firefox
#   Railway Ready (PORT exposed)
# ===============================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Ho_Chi_Minh
ENV PORT=8080

# Virtual display + internal VNC port
ENV DISPLAY=:99
ENV VNC_PORT=5900

# -------------------------------
# Base packages
# -------------------------------
RUN apt update && apt install -y \
    ca-certificates curl tzdata \
    python3 python3-pip \
    xvfb fluxbox x11vnc \
    dbus-x11 xauth x11-xserver-utils \
    fonts-dejavu \
    # Firefox runtime deps (common)
    libgtk-3-0 libdbus-glib-1-2 libasound2 \
    libnss3 libxss1 libxt6 libx11-xcb1 \
    libxcomposite1 libxdamage1 libxrandr2 libxkbcommon0 \
    libgbm1 libpango-1.0-0 libpangocairo-1.0-0 \
    libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    # For extracting firefox (xz or bz2 depending on upstream)
    xz-utils bzip2 \
    && pip3 install --no-cache-dir websockify \
    && ln -fs /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime \
    && dpkg-reconfigure -f noninteractive tzdata \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# -------------------------------
# noVNC static
# -------------------------------
RUN mkdir -p /opt/novnc && \
    curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.4.0.tar.gz \
    | tar -xz --strip-components=1 -C /opt/novnc && \
    ln -s /opt/novnc/vnc.html /opt/novnc/index.html

# -------------------------------
# Firefox (NO SNAP): download official archive
# Handles upstream returning .tar.xz or .tar.bz2
# -------------------------------
RUN set -eux; \
  curl -fsSL -L -o /tmp/firefox.tar "https://download.mozilla.org/?product=firefox-latest&os=linux64&lang=en-US"; \
  (tar -xJf /tmp/firefox.tar -C /opt || tar -xjf /tmp/firefox.tar -C /opt); \
  ln -sf /opt/firefox/firefox /usr/local/bin/firefox; \
  rm -f /tmp/firefox.tar

# -------------------------------
# Entrypoint script (heredoc correct)
# -------------------------------
RUN cat > /usr/local/bin/start-gui.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Timezone: ${TZ}"
echo "Railway PORT: ${PORT}"
echo "DISPLAY: ${DISPLAY}"

# Cleanup old locks (in case of fast restarts)
rm -f /tmp/.X99-lock || true
rm -rf /tmp/.X11-unix/X99 || true
mkdir -p /tmp/.X11-unix

echo "Starting Xvfb..."
Xvfb ${DISPLAY} -screen 0 1280x720x24 -nolisten tcp -ac &
sleep 1

echo "Starting window manager (fluxbox)..."
fluxbox &

echo "Starting VNC server..."
x11vnc -display ${DISPLAY} -forever -shared -rfbport ${VNC_PORT} -nopw -noxrecord -noxfixes -noxdamage &

echo "Starting noVNC on 0.0.0.0:${PORT} -> localhost:${VNC_PORT}"
websockify --web=/opt/novnc 0.0.0.0:${PORT} localhost:${VNC_PORT} &

echo "Starting Firefox..."
while true; do
  firefox --no-remote || true
  sleep 1
done
EOF

RUN chmod +x /usr/local/bin/start-gui.sh

CMD ["/usr/local/bin/start-gui.sh"]
