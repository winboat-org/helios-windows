#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # Upstream experimental Intel acceleration
: "${HELIOS:="N"}"      # Helios Venus acceleration
: "${HELIOS_BOOTSTRAP:="N"}" # Keep standard VGA while staging the KMD
: "${VGA:="virtio"}"    # VGA adaptor
: "${DISPLAY:="web"}"   # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${RENDERNODE:="/dev/dri/renderD128"}"
: "${HELIOS_HOSTMEM:="4G"}"
: "${HELIOS_BLOB_LIMIT:="4G"}"

# Sanitize variables
VGA=$(strip "$VGA")
LOSSY=$(strip "$LOSSY")
DISPLAY=$(strip "$DISPLAY")
RENDERNODE=$(strip "$RENDERNODE")
HELIOS_HOSTMEM=$(strip "$HELIOS_HOSTMEM")
HELIOS_BLOB_LIMIT=$(strip "$HELIOS_BLOB_LIMIT")

port=$(( VNC_PORT - 5900 ))
[[ "$DISPLAY" == ":0" ]] && DISPLAY="web"

LOSSY_OPT=""
enabled "$LOSSY" && LOSSY_OPT=",lossy=on"

configureNvidiaGbmBackend() {
  local allocator=""
  local backend_dir="/run/helios/gbm"

  allocator=$(
    ldconfig -p 2>/dev/null |
      awk '$1 == "libnvidia-allocator.so.1" && !found { print $NF; found=1 }'
  )

  if [ -z "$allocator" ] || [ ! -r "$allocator" ]; then
    error "NVIDIA GBM was requested, but libnvidia-allocator.so.1 is absent from the container linker cache."
    error "Ensure NVIDIA Container Toolkit exposes the graphics driver capability."
    exit 88
  fi

  mkdir -p "$backend_dir"
  ln -sfn "$allocator" "$backend_dir/nvidia-drm_gbm.so"
  export GBM_BACKENDS_PATH="$backend_dir"
}

case "${DISPLAY,,}" in
  "vnc" )
    DISPLAY_OPTS="-display vnc=:${port}${LOSSY_OPT} -vga ${VGA}"
    ;;
  "web" )
    DISPLAY_OPTS="-display vnc=:${port},websocket=${WSS_PORT}${LOSSY_OPT} -vga ${VGA}"
    ;;
  "disabled" )
    DISPLAY_OPTS="-display none -vga ${VGA}"
    ;;
  "none" )
    DISPLAY_OPTS="-display none -vga none"
    ;;
  * )
    DISPLAY_OPTS="-display ${DISPLAY} -vga ${VGA}"
    ;;
esac

# Helios uses the out-of-process Venus renderer from the derived image. Keep
# QEMU's VNC/web transport so the setup remains compatible with WinBoat.
if enabled "$HELIOS"; then
  if [ ! -c "$RENDERNODE" ] || [ ! -r "$RENDERNODE" ] || [ ! -w "$RENDERNODE" ]; then
    error "Helios render device '$RENDERNODE' is unavailable or inaccessible."
    exit 87
  fi

  if [ "${GBM_BACKEND:-}" = "nvidia-drm" ]; then
    configureNvidiaGbmBackend
  fi

  DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
  if enabled "$HELIOS_BOOTSTRAP"; then
    DISPLAY_OPTS+=" -vga std"
  fi
  DISPLAY_OPTS+=" -device virtio-gpu-gl-pci,id=heliosgpu,addr=0x2,max_outputs=1,venus=on,blob=on"
  DISPLAY_OPTS+=",hostmem=$HELIOS_HOSTMEM,max_hostmem=$HELIOS_HOSTMEM"
  DISPLAY_OPTS+=",host3d_blob_limit=$HELIOS_BLOB_LIMIT"

  [[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :${port}${LOSSY_OPT}"
  [[ "${DISPLAY,,}" == "web" ]] && DISPLAY_OPTS+=" -vnc :${port},websocket=${WSS_PORT}${LOSSY_OPT}"
  return 0
fi

if ! enabled "$GPU" || isAmdCpu || [[ "$ARCH" != "amd64" ]]; then
  return 0
fi

case "${APP:-}" in
  "Windows" | "macOS" )
    if ! enabled "$DEBUG"; then
      warn "GPU acceleration is not supported under $APP, ignoring GPU=Y."
      return 0
    fi
    ;;
esac

msg="Configuring display drivers..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

[[ "${VGA,,}" == "virtio" ]] && VGA="virtio-vga-gl"
DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -device $VGA"

[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :${port}${LOSSY_OPT}"
[[ "${DISPLAY,,}" == "web" ]] && DISPLAY_OPTS+=" -vnc :${port},websocket=${WSS_PORT}${LOSSY_OPT}"

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

CARD_NUMBER=$(echo "$RENDERNODE" | grep -oP '(?<=renderD)\d+')
CARD_DEVICE="/dev/dri/card$((CARD_NUMBER - 128))"

if [ ! -c "$CARD_DEVICE" ]; then
  if mknod "$CARD_DEVICE" c 226 $((CARD_NUMBER - 128)); then
    chmod 666 "$CARD_DEVICE"
  fi
fi

if [ ! -c "$RENDERNODE" ]; then
  if mknod "$RENDERNODE" c 226 "$CARD_NUMBER"; then
    chmod 666 "$RENDERNODE"
  fi
fi

if [ ! -c "$RENDERNODE" ] || [ ! -r "$RENDERNODE" ] || [ ! -w "$RENDERNODE" ]; then
  warn "render device '$RENDERNODE' is unavailable or inaccessible."
fi

addPackage "xserver-xorg-video-intel" "Intel GPU drivers"
addPackage "qemu-system-modules-opengl" "OpenGL module"

return 0
