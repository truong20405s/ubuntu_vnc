FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Ho_Chi_Minh
ENV PORT=8080

ENV WIDTH=720
ENV HEIGHT=1280

ENV RAM_MB=1024
ENV CPU_CORES=2
ENV DISK_SIZE=8G

ENV BOOT_FROM_ISO=1
ENV USE_KVM=0

# Direct ISO (tránh HTML /download)
ENV ISO_URL="https://downloads.sourceforge.net/project/android-x86/Release%204.4/android-x86-4.4-r5.iso"

# Build: chỉ cài tối thiểu để tránh timeout
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates curl bash tzdata; \
  rm -rf /var/lib/apt/lists/*; \
  update-ca-certificates

RUN mkdir -p /data /opt/android

RUN cat > /usr/local/bin/start-android.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "TZ=${TZ} PORT=${PORT}"
echo "RES=${WIDTH}x${HEIGHT} RAM_MB=${RAM_MB} CPU_CORES=${CPU_CORES}"
echo "BOOT_FROM_ISO=${BOOT_FROM_ISO} USE_KVM=${USE_KVM}"

# 1) Runtime install (nặng) - chỉ chạy nếu thiếu qemu/websockify/novnc
need_install=0
for bin in qemu-system-x86_64 qemu-img websockify; do
  command -v "$bin" >/dev/null 2>&1 || need_install=1
done

if [ "$need_install" = "1" ]; then
  echo "Installing runtime packages (qemu + novnc)..."
  apt-get update
  apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils \
    xorriso libarchive-tools file \
    novnc websockify
  rm -rf /var/lib/apt/lists/*
fi

ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html 2>/dev/null || true

# 2) Download ISO once (cache in /data)
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
  echo "Patching ISO for video=${WIDTH}x${HEIGHT}..."
  rm -rf /tmp/iso-src
  mkdir -p /tmp/iso-src
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
mkdir -p /data
if [ ! -f /data/android.qcow2 ]; then
  echo "Creating disk /data/android.qcow2 (${DISK_SIZE})..."
  qemu-img create -f qcow2 /data/android.qcow2 "${DISK_SIZE}"
fi

# 5) Start QEMU (VNC on 5900)
KVM_ARGS=()
if [ "${USE_KVM}" = "1" ] && [ -e /dev/kvm ]; then
  KVM_ARGS+=( -enable-kvm -cpu host )
  echo "KVM enabled."
else
  echo "KVM not available: software emulation."
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

echo "Starting QEMU..."
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
EOF

RUN chmod +x /usr/local/bin/start-android.sh

EXPOSE 8080 5900 5555
CMD ["/usr/local/bin/start-android.sh"]
