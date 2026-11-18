---
name: gpu
description: The host's GPU in this container -- Vulkan, OpenGL/EGL, VA-API/QSV video and OpenCL/Level Zero drivers are installed. Use before installing GPU drivers or deciding there is no GPU.
---

# GPU in this container

The drivers are installed; the GPU is whatever the host passed in. Do not
apt-get or pip-install GPU drivers: a driver cannot reach a device the
container was not given.

## Which GPU

```sh
ls /dev/dri                    # renderD128, ... -- none means no GPU here
vulkaninfo --summary           # llvmpipe alone = CPU only
clinfo -l                      # OpenCL
vainfo --display drm --device /dev/dri/renderD128   # video decode/encode
eglinfo -B -p surfaceless      # OpenGL renderer, no display needed
```

No `/dev/dri`, or a render node that cannot be opened: tell the user. The host
has no GPU, or the box was started with `GPUFLAGS=` or before GPU support. On
an NVIDIA host `nvidia-smi` exists only if the NVIDIA Container Toolkit is set
up there.

| API | Intel | AMD | NVIDIA |
|---|---|---|---|
| OpenGL/EGL, Vulkan | Mesa iris, ANV | radeonsi, RADV | host driver via the toolkit; else nouveau, NVK |
| VA-API, QSV | iHD (i965 before Broadwell), oneVPL | Mesa | NVENC/NVDEC via the toolkit |
| OpenCL | NEO, Gen12+ (Tiger Lake on) | rusticl | host driver |
| Level Zero | NEO | - | - |

Intel Gen8-11 OpenCL: `RUSTICL_ENABLE=iris clinfo -l`.

## Video

```sh
ffmpeg -vaapi_device /dev/dri/renderD128 -i in.mp4 \
  -vf 'format=nv12,hwupload' -c:v h264_vaapi out.mp4   # hevc_vaapi, av1_vaapi: where vainfo lists Enc*
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -i in.mp4 -f null -   # decode
ffmpeg -init_hw_device qsv=hw:/dev/dri/renderD128 -i in.mp4 \
  -vf 'format=nv12,hwupload=extra_hw_frames=64' -c:v hevc_qsv out.mp4   # Intel
```

## Browsers

Headless Chromium draws WebGL on SwiftShader, the CPU, unless told otherwise.
These put it on the GPU, Debian's Chromium and both Playwrights alike:

```sh
chromium --headless=new --use-angle=gl-egl ...   # or --use-angle=vulkan --enable-features=Vulkan
p.chromium.launch(args=["--use-angle=gl-egl"])   # Playwright
```

Not `--enable-gpu`: in headless mode it turns WebGL off.

## Compute

- OpenCL: `pip install pyopencl`; link C/C++/Rust against `-lOpenCL`.
- Level Zero: `-lze_loader`, headers in `level_zero/`.
- OpenVINO: `pip install openvino`; its `GPU` device is Intel's runtime.
- Vulkan: `ash` and `wgpu` need nothing more; llama.cpp builds with
  `-DGGML_VULKAN=ON` (glslc is installed).
