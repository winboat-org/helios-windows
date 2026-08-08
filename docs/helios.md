# Helios GPU acceleration

This fork publishes an amd64 image with the Helios QEMU and Venus host stack to
`ghcr.io/winboat-org/helios-windows:latest`.

Pass the host render node into the container and enable Helios with these
Compose fields:

```yaml
environment:
  HELIOS: "Y"
  HELIOS_BOOTSTRAP: "N"
  HELIOS_HOSTMEM: "4G"
  HELIOS_BLOB_LIMIT: "4G"
  RENDERNODE: /dev/dri/renderD128
  VKR_DEVICE_MEMORY_LIMIT_BYTES: "4294967296"
  override_vram_size: "4096"
devices:
  - /dev/kvm
  - /dev/dri/renderD128
```

Hosts using NVIDIA's proprietary driver must install and configure NVIDIA
Container Toolkit for Docker. Request the exact GPU backing the render node and
enable the toolkit's Vulkan/OpenGL libraries in the same service:

```yaml
environment:
  NVIDIA_DRIVER_CAPABILITIES: graphics
  __NV_PRIME_RENDER_OFFLOAD: "1"
  __EGL_VENDOR_LIBRARY_FILENAMES: /usr/share/glvnd/egl_vendor.d/10_nvidia.json
  __GLX_VENDOR_LIBRARY_NAME: nvidia
  __VK_LAYER_NV_optimus: NVIDIA_only
  VK_ICD_FILENAMES: /etc/vulkan/icd.d/nvidia_icd.json
  GBM_BACKEND: nvidia-drm
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          device_ids: [GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx]
          capabilities: [gpu]
```

Use the UUID reported by `nvidia-smi --query-gpu=uuid --format=csv,noheader`.
Passing only `/dev/dri/renderD*` is not enough for the proprietary driver because
the container also needs its matching userspace graphics libraries.
WinBoat accepts either a registered `nvidia` runtime or an NVIDIA CDI spec that
names the selected UUID; use `nvidia-ctk cdi list` to inspect CDI devices.
The NVIDIA environment keeps QEMU's GBM, EGL, GLX, and Vulkan providers on the
same driver. At container startup, Helios resolves the toolkit-injected
`libnvidia-allocator.so.1` through the dynamic linker cache and exposes its GBM
backend from `/run/helios/gbm`. Host distribution library paths are not encoded
in the image or Compose configuration.

If Docker reports `failed to fulfil mount request` for a versioned
`libnvidia-*.so` path, the failure occurs before the Helios entrypoint runs.
Recreate the container after changing the host NVIDIA driver so Docker can
resolve the current driver mounts. If a newly created container has the same
error, repair the host driver/toolkit installation, run `sudo ldconfig`, and
refresh the CDI specification with
`sudo systemctl restart nvidia-cdi-refresh.service`
(NVIDIA Container Toolkit 1.18 or newer). `nvidia-ctk --debug cdi list` reports
which specification still references a missing host path.

Set `HELIOS_BOOTSTRAP=Y` while installing the Windows driver to keep a standard
VGA device available. Set it back to `N` after the driver-restart checkpoint.

When Helios is enabled with KVM, the image starts QEMU with
`-accel kvm,honor-guest-pat=on`; the qemux `-machine ...,accel=kvm` form is
replaced rather than combined with it.

The image is based on the current upstream Dockur image. QEMU and
virglrenderer are pinned in `Dockerfile.helios` so a rebuild uses the tested
host graphics stack.
