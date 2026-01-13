# ===============================
#   DEBIAN SLIM + noVNC + Chromium
#   Railway Ready (PORT exposed)
# ===============================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Ho_Chi_Minh
ENV PORT=8080

ENV DISPLAY=:99
ENV VNC_PORT=5900

# -------------------------------
# Base packages (no recommends)
# -------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl tzdata \
    xvfb fluxbox x11vnc \
    dbus-x11 xauth x11-xserver-utils \
    fonts-dejavu \
    # Browser
    chromium \
    # noVNC + websockify
    novnc websockify \
    && ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime \
    && dpkg-reconfigure -f noninteractive tzdata \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Debian novnc package thường đặt web ở /usr/share/novnc
# Tạo index.html cho tiện
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html || true

# -------------------------------
# Entrypoint
# -------------------------------
RUN cat > /usr/local/bin/start-gui.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Timezone: ${TZ}"
echo "Railway PORT: ${PORT}"
echo "DISPLAY: ${DISPLAY}"

rm -f /tmp/.X99-lock || true
rm -rf /tmp/.X11-unix/X99 || true
mkdir -p /tmp/.X11-unix

echo "Starting Xvfb..."
# Giảm RAM: hạ resolution + depth 16-bit
Xvfb ${DISPLAY} -screen 0 1024x576x16 -nolisten tcp -ac &

sleep 1
echo "Starting window manager (fluxbox)..."
fluxbox &

echo "Starting VNC server..."
x11vnc -display ${DISPLAY} -forever -shared -rfbport ${VNC_PORT} -nopw -noxrecord -noxfixes -noxdamage &

echo "Starting noVNC on 0.0.0.0:${PORT} -> localhost:${VNC_PORT}"
websockify --web=/usr/share/novnc 0.0.0.0:${PORT} localhost:${VNC_PORT} &

echo "Starting Chromium..."
# Flags giảm tài nguyên:
# - --no-sandbox: cần cho container không đặc quyền (chấp nhận trade-off bảo mật)
# - --disable-dev-shm-usage: tránh /dev/shm nhỏ gây crash
# - tắt GPU/extension/background noise
# - có thể thêm --blink-settings=imagesEnabled=false để tắt ảnh (nếu chỉ “treo”)
while true; do
  chromium \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-extensions \
    --disable-background-networking \
    --disable-sync \
    --metrics-recording-only \
    --no-first-run \
    --disable-features=Translate,BackForwardCache,PreloadMediaEngagementData,MediaRouter \
    about:blank || true
  sleep 1
done
EOF

RUN chmod +x /usr/local/bin/start-gui.sh
CMD ["/usr/local/bin/start-gui.sh"]
