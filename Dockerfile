# ===============================
#   ALPINE + noVNC + Chromium
#   Railway Ready (PORT exposed)
# ===============================
FROM alpine:3.19

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Ho_Chi_Minh
ENV PORT=8080
ENV DISPLAY=:99
ENV VNC_PORT=5900

# -------------------------------
# Base packages + GUI stack
# -------------------------------
RUN apk add --no-cache \
    # System essentials
    ca-certificates tzdata bash \
    # X11 + VNC
    xvfb x11vnc fluxbox \
    dbus xauth xrandr \
    # Fonts (minimal)
    font-noto \
    # Browser
    chromium \
    # Python + pip for websockify
    python3 py3-pip \
    && pip3 install --no-cache-dir websockify \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime

# Tải noVNC từ GitHub (vì Alpine không có package novnc)
RUN wget -qO- https://github.com/novnc/noVNC/archive/v1.4.0.tar.gz | tar xz -C /opt \
    && mv /opt/noVNC-1.4.0 /opt/novnc \
    && ln -sf /opt/novnc/vnc.html /opt/novnc/index.html

# -------------------------------
# Entrypoint Script
# -------------------------------
RUN cat > /usr/local/bin/start-gui.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "=== Alpine VNC Container ==="
echo "PORT: ${PORT} | DISPLAY: ${DISPLAY}"

# Cleanup X11 locks
rm -rf /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
mkdir -p /tmp/.X11-unix

echo "[1/4] Starting Xvfb..."
Xvfb ${DISPLAY} -screen 0 1024x576x16 -nolisten tcp -ac &
sleep 2

echo "[2/4] Starting Fluxbox..."
fluxbox &

echo "[3/4] Starting x11vnc..."
x11vnc -display ${DISPLAY} -forever -shared -rfbport ${VNC_PORT} \
       -nopw -noxrecord -noxfixes -noxdamage -quiet &

echo "[4/4] Starting noVNC..."
websockify --web=/opt/novnc 0.0.0.0:${PORT} localhost:${VNC_PORT} &

sleep 3
echo "✓ Chromium starting..."

while true; do
  chromium-browser \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --disable-extensions \
    --disable-background-networking \
    --no-first-run \
    --window-size=1024,576 \
    about:blank 2>/dev/null || true
  sleep 2
done
EOF

RUN chmod +x /usr/local/bin/start-gui.sh

CMD ["/usr/local/bin/start-gui.sh"]
