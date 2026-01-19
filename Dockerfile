# ===============================
#   ALPINE + noVNC + Chromium
#   Railway Ready (Fully Fixed)
# ===============================
FROM alpine:3.19

ENV TZ=Asia/Ho_Chi_Minh \
    PORT=8080 \
    DISPLAY=:99 \
    VNC_PORT=5900

# -------------------------------
# Install packages (single layer)
# -------------------------------
RUN apk add --no-cache \
    ca-certificates tzdata bash curl \
    xvfb x11vnc fluxbox dbus xauth xrandr \
    font-noto chromium \
    python3 py3-numpy && \
    # Install websockify globally (bypass venv)
    python3 -m ensurepip && \
    pip3 install --break-system-packages websockify && \
    # Download noVNC
    curl -fsSL https://github.com/novnc/noVNC/archive/v1.4.0.tar.gz | \
    tar xz -C /opt && \
    mv /opt/noVNC-1.4.0 /opt/novnc && \
    ln -sf /opt/novnc/vnc.html /opt/novnc/index.html && \
    ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && \
    # Cleanup
    rm -rf /var/cache/apk/* /root/.cache

# -------------------------------
# Startup Script
# -------------------------------
RUN cat > /start.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🐧 Alpine VNC Container"
echo "🌐 Access: http://localhost:${PORT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Clean X11 locks
rm -rf /tmp/.X* 2>/dev/null || true
mkdir -p /tmp/.X11-unix

# Start services
echo "[1/5] Xvfb..."
Xvfb ${DISPLAY} -screen 0 1280x720x16 -nolisten tcp -ac &
sleep 2

echo "[2/5] Fluxbox..."
fluxbox &

echo "[3/5] x11vnc..."
x11vnc -display ${DISPLAY} -forever -shared \
       -rfbport ${VNC_PORT} -nopw -quiet &

echo "[4/5] websockify..."
websockify --web=/opt/novnc 0.0.0.0:${PORT} localhost:${VNC_PORT} &

sleep 3
echo "[5/5] Chromium..."

# Keep browser alive
while true; do
  chromium-browser \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --disable-extensions \
    --disable-background-networking \
    --disable-sync \
    --no-first-run \
    --window-size=1280,720 \
    --user-data-dir=/tmp/chrome \
    about:blank 2>/dev/null || true
  sleep 2
done
SCRIPT

RUN chmod +x /start.sh

# -------------------------------
# Health check (optional)
# -------------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s \
  CMD curl -f http://localhost:${PORT} || exit 1

CMD ["/start.sh"]
