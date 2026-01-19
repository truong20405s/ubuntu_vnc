# Alpine nhỏ, pull nhanh; lưu ý: RAM khi chạy Chromium vẫn là chính
FROM alpine:3.19

ENV TZ=Asia/Ho_Chi_Minh
ENV PORT=8080

ENV DISPLAY=:99
ENV VNC_PORT=5900

# Bật community repo (novnc/websockify/x11vnc/xvfb thường nằm ở community)
RUN set -eux; \
  ALPINE_VER="$(cut -d. -f1,2 /etc/alpine-release)"; \
  echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main" > /etc/apk/repositories; \
  echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories; \
  apk add --no-cache \
    ca-certificates tzdata \
    # X virtual framebuffer + WM
    xvfb fluxbox \
    # VNC server + noVNC/websockify
    x11vnc novnc websockify \
    # Browser
    chromium \
    # Fonts (tránh lỗi ô vuông)
    ttf-dejavu fontconfig \
  ; \
  update-ca-certificates

# noVNC thường nằm ở /usr/share/novnc, tạo index.html cho tiện
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html 2>/dev/null || true

RUN cat > /usr/local/bin/start-gui.sh <<'EOF'
#!/bin/sh
set -eu

echo "TZ=${TZ}"
echo "PORT=${PORT}"
echo "DISPLAY=${DISPLAY}"

# Xvfb lock cleanup (an toàn khi restart)
rm -f /tmp/.X99-lock 2>/dev/null || true
rm -rf /tmp/.X11-unix/X99 2>/dev/null || true
mkdir -p /tmp/.X11-unix

echo "Starting Xvfb..."
# Hạ RAM: giảm resolution + 16-bit depth
Xvfb "${DISPLAY}" -screen 0 1366x768x16 -nolisten tcp -ac &
sleep 1

echo "Starting window manager (fluxbox)..."
fluxbox >/dev/null 2>&1 &
sleep 1

echo "Starting VNC server..."
x11vnc \
  -display "${DISPLAY}" \
  -forever -shared \
  -rfbport "${VNC_PORT}" \
  -nopw \
  -noxrecord -noxfixes -noxdamage \
  >/dev/null 2>&1 &

echo "Starting noVNC on 0.0.0.0:${PORT} -> localhost:${VNC_PORT}"
websockify --web=/usr/share/novnc "0.0.0.0:${PORT}" "localhost:${VNC_PORT}" >/dev/null 2>&1 &

echo "Starting Chromium (non-headless)..."
# Mẹo giảm tài nguyên:
# - renderer-process-limit=1: giới hạn renderer process
# - tắt sync/extension/background networking
# - tắt ảnh nếu chỉ cần điều khiển logic (bạn có thể bỏ dòng blink-settings nếu cần xem hình)
# - user-data-dir đặt ở /tmp để tránh phình disk cache
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
    --renderer-process-limit=1 \
    --disk-cache-size=1 \
    --media-cache-size=1 \
    --user-data-dir=/tmp/chrome-profile \
    --blink-settings=imagesEnabled=false \
    about:blank >/dev/null 2>&1 || true
  sleep 1
done
EOF

RUN chmod +x /usr/local/bin/start-gui.sh
CMD ["/usr/local/bin/start-gui.sh"]
