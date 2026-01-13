#!/usr/bin/env bash
set -euo pipefail

trap 'echo "FATAL: startup failed"; echo "--- qemu.log ---"; tail -200 /var/log/qemu.log 2>/dev/null || true; echo "--------------"; exit 1' ERR

echo "PORT=${PORT} TZ=${TZ}"
echo "RES=${WIDTH}x${HEIGHT} RAM_MB=${RAM_MB} CPU_CORES=${CPU_CORES}"

mkdir -p /data

# 0) MỞ PORT NGAY (để Railway healthcheck không kill)
# Cần python3 trong image build (cài nhẹ) hoặc bạn thay bằng busybox httpd nếu có.
python3 -m http.server "${PORT}" --bind 0.0.0.0 >/tmp/boot-http.log 2>&1 &
BOOT_HTTP_PID=$!
echo "Boot HTTP up (pid=${BOOT_HTTP_PID})"

# 1) Runtime install (retry)
need_install=0
for bin in qemu-system-x86_64 qemu-img websockify; do
  command -v "$bin" >/dev/null 2>&1 || need_install=1
done

if [ "$need_install" = "1" ]; then
  echo "Installing runtime packages..."
  for i in 1 2 3; do
    apt-get update && \
    apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils \
      xorriso libarchive-tools file \
      novnc websockify \
    && break || (echo "apt failed attempt $i"; sleep 3)
  done
  rm -rf /var/lib/apt/lists/*
fi

ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html 2>/dev/null || true

# 2) Download ISO (cache)
if [ ! -f /data/android.iso ]; then
  echo "Downloading ISO..."
  curl -L --retry 8 --retry-delay 2 --connect-timeout 20 --max-time 1200 \
    -A "Mozilla/5.0" \
    -o /data/android.iso "${ISO_URL}"
fi

echo "Verifying ISO..."
file /data/android.iso | tee /tmp/iso_type.txt
grep -qi "ISO 9660" /tmp/iso_type.txt

# 3) Patch ISO once (cache)
if [ ! -f /data/android-patched.iso ]; then
  echo "Patching ISO video=${WIDTH}x${HEIGHT}"
  rm -rf /tmp/iso-src && mkdir -p /tmp/iso-src
  bsdtar -C /tmp/iso-src -xf /data/android.iso

  if [ -f /tmp/iso-src/isolinux/isolinux.cfg ]; then
    sed -i -E "s@(APPEND[[:space:]]+.*)@\\1 video=${WIDTH}x${HEIGHT}@g" /tmp/iso-src/isolinux/isolinux.cfg || true
    sed -i -E "s@(append[[:space:]]+.*)@\\1 video=${WIDTH}x${HEIGHT}@g" /tmp/iso-src/isolinux/isolinux.cfg || true
  fi

  for f in /tmp/iso-src/boot/grub/grub.cfg /tmp/iso-src/EFI/BOOT/grub.cfg; do
    if [ -f "$f" ]; then
      sed -i -E "s@(linux[[:space:]].*)@\\1 video=${WIDTH}x${HEIGHT}@g" "$f" || true
    fi
  done

  xorriso -as mkisofs \
    -o /data/android-patched.iso \
    -V "ANDROIDx86_4.4_PATCHED" \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    /tmp/iso-src
  rm -rf /tmp/iso-src
fi

# 4) Create disk
if [ ! -f /data/android.qcow2 ]; then
  qemu-img create -f qcow2 /data/android.qcow2 "${DISK_SIZE}"
fi

# 5) Stop temporary HTTP, then start real noVNC on same PORT
kill "${BOOT_HTTP_PID}" 2>/dev/null || true
echo "Boot HTTP stopped; starting QEMU + noVNC..."

# 6) Start QEMU
KVM_ARGS=()
if [ "${USE_KVM}" = "1" ] && [ -e /dev/kvm ]; then
  KVM_ARGS+=( -enable-kvm -cpu host )
fi

NET_ARGS=( -netdev user,id=n1,hostfwd=tcp::5555-:5555 -device e1000,netdev=n1 )
VNC_ARGS=( -vnc 0.0.0.0:0 -display none )
DISK_ARGS=( -drive file=/data/android.qcow2,if=virtio,format=qcow2 )

ISO_ARGS=()
BOOT_ARGS=( -boot order=c,menu=on )
if [ "${BOOT_FROM_ISO}" = "1" ]; then
  ISO_ARGS=( -cdrom /data/android-patched.iso )
  BOOT_ARGS=( -boot order=d,menu=on )
fi

qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -m "${RAM_MB}" \
  -smp "${CPU_CORES}" \
  -machine pc \
  -device virtio-vga \
  "${DISK_ARGS[@]}" \
  "${ISO_ARGS[@]}" \
  "${BOOT_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  "${VNC_ARGS[@]}" \
  >/var/log/qemu.log 2>&1 &

echo "noVNC: http://0.0.0.0:${PORT}/"
exec websockify --web=/usr/share/novnc "0.0.0.0:${PORT}" "localhost:5900"
