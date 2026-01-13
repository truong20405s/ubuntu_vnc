# Android-x86 4.4 (KitKat) in QEMU + noVNC
# - One-file Dockerfile: builds image + embeds all scripts
# - Exposes a web VNC client at PORT (default 8080)
# - Patches boot config to request "phone-like" resolution via kernel param: video=WxH

FROM debian:bookworm-slim

ENV TZ=Asia/Ho_Chi_Minh
ENV PORT=8080

# "Phone-like" resolution; you can override at runtime: -e WIDTH=720 -e HEIGHT=1280
ENV WIDTH=720
ENV HEIGHT=1280

# VM sizing (override at runtime)
ENV RAM_MB=1024
ENV CPU_CORES=2
ENV DISK_SIZE=8G

# Boot mode:
#  - BOOT_FROM_ISO=1 : attach ISO, boot order CD first (for first-time install)
#  - BOOT_FROM_ISO=0 : boot from disk only (after install)
ENV BOOT_FROM_ISO=1

# Optional KVM acceleration (if running on a server that provides /dev/kvm to container)
ENV USE_KVM=0

# Android-x86 4.4-r5 ISO (official SourceForge release notes mention this ISO) :contentReference[oaicite:1]{index=1}
# You can override ISO_URL at build time: --build-arg ISO_URL=...
ARG ISO_URL="https://sourceforge.net/projects/android-x86/files/Release%204.4/android-x86-4.4-r5.iso/download"

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl tzdata \
    qemu-system-x86 qemu-utils \
    xorriso isolinux \
    libarchive-tools \
    novnc websockify \
  ; \
  rm -rf /var/lib/apt/lists/*; \
  update-ca-certificates

# Convenience: noVNC index
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html 2>/dev/null || true

# Download ISO, patch boot configs to inject "video=WIDTHxHEIGHT"
# Android-x86 supports setting custom resolution via kernel cmdline "video=..." :contentReference[oaicite:2]{index=2}
RUN set -eux; \
  mkdir -p /opt/android /tmp/iso-src /tmp/iso-new; \
  echo "Downloading Android-x86 ISO..."; \
  curl -L --retry 5 --retry-delay 2 -o /opt/android/android.iso "${ISO_URL}"; \
  echo "Extracting ISO..."; \
  bsdtar -C /tmp/iso-src -xf /opt/android/android.iso; \
  \
  # Patch ISOLINUX (legacy BIOS) config if present
  if [ -f /tmp/iso-src/isolinux/isolinux.cfg ]; then \
    sed -i -E "s@(APPEND[[:space:]]+.*)@\\1 video=${WIDTH}x${HEIGHT}@g" /tmp/iso-src/isolinux/isolinux.cfg || true; \
    sed -i -E "s@(append[[:space:]]+.*)@\\1 video=${WIDTH}x${HEIGHT}@g" /tmp/iso-src/isolinux/isolinux.cfg || true; \
  fi; \
  \
  # Patch GRUB (UEFI) configs if present
  for f in /tmp/iso-src/boot/grub/grub.cfg /tmp/iso-src/EFI/BOOT/grub.cfg; do \
    if [ -f "$f" ]; then \
      sed -i -E "s@(linux[[:space:]].*)@\\1 video=${WIDTH}x${HEIGHT}@g" "$f" || true; \
    fi; \
  done; \
  \
  # Repack ISO with BIOS El Torito boot; add UEFI boot if EFI image exists
  echo "Repacking patched ISO..."; \
  ISOMBR="/usr/lib/ISOLINUX/isohdpfx.bin"; \
  BIOS_ARGS="-c isolinux/boot.cat -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table"; \
  if [ -f /tmp/iso-src/EFI/boot/bootx64.efi ]; then \
    UEFI_ARGS="-eltorito-alt-boot -e EFI/boot/bootx64.efi -no-emul-boot -isohybrid-gpt-basdat"; \
  else \
    UEFI_ARGS=""; \
  fi; \
  xorriso -as mkisofs \
    -o /opt/android/android-patched.iso \
    -isohybrid-mbr "${ISOMBR}" \
    ${BIOS_ARGS} \
    ${UEFI_ARGS} \
    -V "ANDROIDx86_4.4_PATCHED" \
    /tmp/iso-src; \
  \
  rm -rf /tmp/iso-src /tmp/iso-new

# Start script: QEMU provides VNC (:0 => 5900). websockify/noVNC exposes it on PORT.
RUN cat > /usr/local/bin/start-android.sh <<'EOF'
#!/bin/bash
set -euo pipefail

echo "TZ=${TZ}"
echo "PORT=${PORT}"
echo "Resolution request: ${WIDTH}x${HEIGHT}"
echo "VM: RAM_MB=${RAM_MB}, CPU_CORES=${CPU_CORES}, DISK_SIZE=${DISK_SIZE}"
echo "BOOT_FROM_ISO=${BOOT_FROM_ISO} (1=install/first boot, 0=boot from disk)"
echo "USE_KVM=${USE_KVM}"

mkdir -p /data

# Create persistent disk if missing
if [ ! -f /data/android.qcow2 ]; then
  echo "Creating disk /data/android.qcow2 (${DISK_SIZE})..."
  qemu-img create -f qcow2 /data/android.qcow2 "${DISK_SIZE}"
fi

KVM_ARGS=()
if [ "${USE_KVM}" = "1" ] && [ -e /dev/kvm ]; then
  echo "KVM detected: enabling hardware acceleration."
  KVM_ARGS+=( -enable-kvm -cpu host )
else
  echo "KVM not enabled/available: using software emulation (slow)."
fi

# Networking: user-mode; expose host TCP 5555 -> guest 5555 (ADB over TCP, if you enable it inside Android)
NET_ARGS=( -netdev user,id=n1,hostfwd=tcp::5555-:5555 -device e1000,netdev=n1 )

# VNC server on 0.0.0.0:5900
VNC_ARGS=( -vnc 0.0.0.0:0 -display none )

# Disk (virtio is usually faster)
DISK_ARGS=( -drive file=/data/android.qcow2,if=virtio,format=qcow2 )

# ISO attach for first-time install
ISO_ARGS=()
BOOT_ARGS=( -boot order=c,menu=on )
if [ "${BOOT_FROM_ISO}" = "1" ]; then
  ISO_ARGS=( -cdrom /opt/android/android-patched.iso )
  BOOT_ARGS=( -boot order=d,menu=on )
fi

# Run QEMU in background
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

QEMU_PID=$!
echo "QEMU PID=${QEMU_PID}"
echo "VNC: tcp/5900  |  noVNC: http://<host>:${PORT}/ (path: /vnc.html or /index.html)"

# Foreground websockify (PID 1)
exec websockify --web=/usr/share/novnc "0.0.0.0:${PORT}" "localhost:5900"
EOF

RUN chmod +x /usr/local/bin/start-android.sh

EXPOSE 8080 5900 5555
CMD ["/usr/local/bin/start-android.sh"]
