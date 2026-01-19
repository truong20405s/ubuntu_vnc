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
    font-noto font-noto-emoji \
    # Browser
    chromium \
    # noVNC stack
    py3-numpy py3-websockify novnc \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime

# Alpine's novnc package stores files in /usr/share/webapps/novnc
RUN ln -sf /usr/share/webapps/novnc/vnc.html /usr/share/webapps/novnc/index.html || true

# -------------------------------
# Entrypoint Script
# -------------------------------
RUN cat > /usr/local/bin/start-gui.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "=== Container Info ==="
echo "OS: Alpine Linux"
echo "Timezone: ${TZ}"
echo "Railway PORT: ${PORT}"
echo "DISPLAY: ${DISPLAY}"

# Cleanup X11 locks
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
mkdir -p /tmp/.X11-unix

echo "Starting Xvfb (Virtual Display)..."
Xvfb ${DISPLAY} -screen 0 1024x576x16 -nolisten tcp -ac &
sleep 2

echo "Starting Fluxbox (Window Manager)..."
fluxbox &

echo "Starting x11vnc (VNC Server)..."
x11vnc -display ${DISPLAY} -forever -shared -rfbport ${VNC_PORT} \
       -nopw -noxrecord -noxfixes -noxdamage -quiet &

echo "Starting noVNC (WebSocket Proxy)..."
# Alpine path differs from Debian
websockify --web=/usr/share/webapps/novnc \
           0.0.0.0:${PORT} localhost:${VNC_PORT} &

sleep 3
echo "Starting Chromium..."

# Keep Chromium alive with auto-restart
while true; do
  chromium-browser \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --disable-extensions \
    --disable-background-networking \
    --disable-sync \
    --disable-translate \
    --disable-features=TranslateUI,BackForwardCache \
    --no-first-run \
    --no-default-browser-check \
    --window-size=1024,576 \
    about:blank 2>/dev/null || true
  sleep 2
done
EOF

RUN chmod +x /usr/local/bin/start-gui.sh

# -------------------------------
# Launch
# -------------------------------
CMD ["/usr/local/bin/start-gui.sh"]
