# ===============================
#   Alpine + Xvfb + Fluxbox + x11vnc + noVNC (upstream) + Chromium
#   - Fix lỗi noVNC UI (lệch file/DOM) bằng cách dùng noVNC upstream
#   - Root "/" tự redirect sang vnc_lite.html (mặc định) hoặc vnc.html (tuỳ ENV)
#   - websockify dùng --wrap-mode=ignore cho ổn định
# ===============================
FROM alpine:3.23

ENV TZ=Asia/Ho_Chi_Minh
ENV PORT=8080

ENV DISPLAY=:99
ENV VNC_PORT=5900

# noVNC options
# NOVNC_LITE=1  => dùng vnc_lite.html (nhẹ, ít UI, ít lỗi)
# NOVNC_LITE=0  => dùng vnc.html (đầy đủ UI)
ENV NOVNC_LITE=1
ENV NOVNC_AUTOCONNECT=1

# Chromium options
ENV CHROMIUM_URL=about:blank

# Bật community repo (x11vnc/xvfb/fluxbox/websockify thường ở community)
RUN set -eux; \
  ALPINE_VER="$(cut -d. -f1,2 /etc/alpine-release)"; \
  echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main" > /etc/apk/repositories; \
  echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories; \
  apk add --no-cache \
    ca-certificates tzdata \
    curl tar \
    # X virtual framebuffer + window manager
    xvfb fluxbox \
    # VNC server + websocket proxy
    x11vnc websockify \
    # Browser
    chromium \
    # Fonts (tránh lỗi ô vuông)
    ttf-dejavu fontconfig \
  ; \
  update-ca-certificates

# Cài noVNC upstream để tránh lệch layout/file giữa HTML và app/ui.js
# Pin version để ổn định
ARG NOVNC_VERSION=v1.5.0
RUN set -eux; \
  mkdir -p /opt; \
  curl -L -o /tmp/novnc.tgz "https://github.com/novnc/noVNC/archive/refs/tags/${NOVNC_VERSION}.tar.gz"; \
  tar -xzf /tmp/novnc.tgz -C /opt; \
  mv /opt/noVNC-* /opt/novnc; \
  rm -f /tmp/novnc.tgz; \
  # đảm bảo có thư mục web root
  test -f /opt/novnc/vnc.html

RUN cat > /usr/local/bin/start-gui.sh <<'EOF'
#!/bin/sh
set -eu

# Defaults (trong trường hợp platform không inject)
: "${TZ:=UTC}"
: "${PORT:=8080}"
: "${DISPLAY:=:99}"
: "${VNC_PORT:=5900}"
: "${NOVNC_LITE:=1}"
: "${NOVNC_AUTOCONNECT:=1}"
: "${CHROMIUM_URL:=about:blank}"

echo "TZ=${TZ}"
echo "PORT=${PORT}"
echo "DISPLAY=${DISPLAY}"
echo "VNC_PORT=${VNC_PORT}"
echo "NOVNC_LITE=${NOVNC_LITE}"
echo "CHROMIUM_URL=${CHROMIUM_URL}"

# Xvfb lock cleanup (an toàn khi restart)
rm -f /tmp/.X99-lock 2>/dev/null || true
rm -rf /tmp/.X11-unix/X99 2>/dev/null || true
mkdir -p /tmp/.X11-unix

# Root "/" redirect về trang noVNC phù hợp
if [ "${NOVNC_LITE}" = "1" ]; then
  PAGE="vnc_lite.html"
else
  PAGE="vnc.html"
fi

PARAMS="autoconnect=${NOVNC_AUTOCONNECT}&resize=remote"
printf '%s\n' \
  "<!doctype html><meta http-equiv=\"refresh\" content=\"0; url=/${PAGE}?${PARAMS}\">" \
  > /opt/novnc/index.html

echo "Starting Xvfb..."
# Hạ RAM: giảm resolution + 16-bit depth
Xvfb "${DISPLAY}" -screen 0 1366x768x16 -nolisten tcp -ac &
sleep 1

echo "Starting window manager (fluxbox)..."
fluxbox >/dev/null 2>&1 &
sleep 1

echo "Starting VNC server..."
# -localhost: không mở cổng VNC ra ngoài internet (chỉ websockify dùng localhost)
x11vnc \
  -display "${DISPLAY}" \
  -forever -shared \
  -rfbport "${VNC_PORT}" \
  -localhost \
  -nopw \
  -noxrecord -noxfixes -noxdamage \
  >/dev/null 2>&1 &
sleep 1

echo "Starting noVNC on 0.0.0.0:${PORT} -> localhost:${VNC_PORT}"
websockify \
  --web=/opt/novnc \
  --wrap-mode=ignore \
  "0.0.0.0:${PORT}" \
  "localhost:${VNC_PORT}" \
  >/dev/null 2>&1 &

echo "Starting Chromium (non-headless)..."
# Mẹo giảm tài nguyên:
# - renderer-process-limit=1: giới hạn renderer process
# - tắt sync/extension/background networking
# - user-data-dir đặt ở /tmp để tránh phình disk cache
# - disk/media cache size cực nhỏ
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
    "${CHROMIUM_URL}" >/dev/null 2>&1 || true
  sleep 1
done
EOF

RUN chmod +x /usr/local/bin/start-gui.sh

# (Tuỳ platform) - không bắt buộc nhưng rõ ràng
EXPOSE 8080

CMD ["/usr/local/bin/start-gui.sh"]
