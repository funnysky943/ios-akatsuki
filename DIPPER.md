# Porting `youzjuzi/dipper-xnu` to the Xperia XZ3 (`akatsuki`)

Branch: **`dipper-port`**, based on the working iOS 16.7.16 XZ3 tree (`main`, `d6d5556`).

This document records what was taken from [dipper-xnu](https://github.com/youzjuzi/dipper-xnu),
what was deliberately left out, and the order in which the remaining work has to happen.

## Why this base

`dipper-xnu` is an iOS **16.5** / **xnu-8796.121.2** stack, the same XNU generation as this tree
(iOS 16.7.16 runs on xnu-8796.141.3). The XZ3 side already boots that userland to the home
screen, has working display and RMI4 touch, and its kernel Adreno 630 bring-up is complete
through an **msm-compatible IOKit user client** (`SweetAdreno630`).

The valuable missing piece is exactly the part dipper solved: a **userspace OpenGL ES stack**
that CoreAnimation can use behind `EAGLContext`, with Mesa/freedreno driving the Adreno and an
IOSurface path that avoids copies.

## What was imported

`tools/redwood/` contains the graphics subset of dipper-xnu's userland:

| Path | Origin | Purpose |
| --- | --- | --- |
| `tools/redwood/src/eagl.c` | `userland/src/eagl.c` | OpenGL ES implementation behind `EAGLContext`, used by CoreAnimation's window server |
| `tools/redwood/src/gl_osmesa.c`, `redwood_gl.h` | same | Adapter from `eagl.c` to Mesa's OSMesa context API |
| `tools/redwood/src/mkeagl.py`, `eagl_slots.txt` | `userland/` | Generates the OpenGLES dispatch table from iOS's `getMacroContextPrivate` slot list |
| `tools/redwood/mesa/*.patch` | `tools/mesa/` | Mesa 25.0.7 patches: freedreno-without-DRM, OSMesa ES profile, ir3 fixes, optional AIR/Metal |
| `tools/redwood/mesa/redwood-drm/` | `tools/mesa/redwood-drm/` | libdrm stand-in that forwards DRM ioctls to the IOKit GPU client |
| `tools/redwood/mesa/air/` | `tools/mesa/air/` | Apple AIR bitcode → NIR frontend (Metal path, optional for now) |
| `tools/redwood/src/gl_test.c` | `userland/src/gl_test.c` | Standalone triangle/renderback probe (adapted to write a PPM instead of using RedwoodGPU's panel selector) |
| `tools/redwood/mk-mesa.sh` | `tools/mk-mesa.sh` | Linux cross-build of Mesa for iOS, using this host's clang/ld64.lld and the 16.5 SDK |
| `tools/redwood/build-gl.sh` | new | Builds `libredwood-gl.dylib` and `gl_test` |

The kernel side is **not** imported: this tree already has the full Adreno 630 stack
(patches `0099`–`0164`). The userspace ABI bridge was changed in one file:

- service `RedwoodGPU` → **`SweetAdreno630`**
- IOSurface request `0x7e` + `struct redwood_surface` → **`0x71` + `struct sweet_gpu_surface_bo`**
- BO mapping now asks for `kIOMapWriteCombineCache`, matching
  `iokit/Kernel/arm/SweetAdrenoABI.h`
- everything else is the Linux msm request numbering (`DRM_COMMAND_BASE + index`) and Linux
  structure layouts, which the XZ3 client already implements.

## What is deliberately not imported

- **edk2-sdm845 UEFI, xnuloader, APFS `darwin` partition** — the XZ3 keeps its safe shim boot,
  `userdata` HFS+ root and `fastboot boot` workflow. UEFI is known to brick this device.
- `mi8_adreno.c`, `RedwoodGPU.cpp` — the XZ3 kernel GPU driver is already further along for this
  board (GMEM, SMMU, CP, zap, fences, msm selectors).
- `mi8_*` (FTS touch, TAS2557 audio, WCN3990 Wi-Fi/BT, glink/rproc) — Mi 8 hardware. The XZ3 has
  RMI4 touch, no WCN3990 and no TAS2557.
- `redwood_ufs.c` / APFS storage code, `mi8_hostsvc`, `mi8_lx` — not applicable to this boot
  chain.

## Architecture of the ported path

```
SpringBoard / backboardd
        |  CoreAnimation
        v
EAGLContext  --replaced by-->  libredwood-gl.dylib (eagl.c)
        |                         |  gl* calls
        |                         v
        |                    libOSMesa.8.dylib  (Mesa 25.0.7, freedreno + softpipe)
        |                         |  drmIoctl / drmPrimeFDToHandle / map
        |                         v
        |                    redwood-drm (libdrm stand-in)
        |                         |  IOConnectCallStructMethod(0x40..0x48, 0x71)
        |                         v
        |                    SweetAdreno630 user client (XZ3 kernel)
        v
IOSurface memory  <-- zero-copy texture / render target when the surface can be a BO
```

`eagl.c` either wraps an IOSurface as a GPU BO (`redwood_gl_surface_texture`, using selector
`0x71`) or, when that is impossible, copies the surface into a normal texture and reads it back
at frame end. Both paths are CPU-visible; only the first avoids the copies.

## Phases and current state

### Phase 0 — host cross-build (in progress)

- [x] branch `dipper-port` re-based onto `main` (`d6d5556`) and force-pushed
- [x] dipper's graphics subset imported under `tools/redwood/`
- [x] libdrm stand-in adapted to `SweetAdreno630` / selector `0x71` / write-combined mapping
- [ ] Mesa 25.0.7 cross-build (`tools/redwood/mk-mesa.sh`)
- [ ] `libredwood-gl.dylib` + `gl_test` link (`tools/redwood/build-gl.sh`)
- [ ] inspect the resulting Mach-Os (arch, platform, install names, no host paths)

### Phase 1 — prove the ABI on the phone, without the window server

- install `libOSMesa.8.dylib`, `gl_test` in the iOS root (`/redwood/lib`, `/usr/local/bin`)
- start `gl_test` from a **normal LaunchDaemon**, not from `/sbin/launchd`
  (the init task has no user client rights on this kernel; a previous `libdrm-test` run from
  init panicked)
- expected log: Mesa vendor/renderer strings naming **freedreno** (not softpipe), a 1440×2880
  or 1125×2436 triangle, nonzero "pixels inside the triangle", and `/tmp/gl_test.ppm`
- fallback: `OSMESA_SOFTWARE=1` must produce the same picture through softpipe, proving the
  build itself before blaming the GPU

### Phase 2 — CoreAnimation in `backboardd`

This is the part that needs iOS 16.7.16-specific work, because dipper's `inject.c` uses
**absolute dyld-shared-cache addresses from iOS 16.5 (20F66)**:

1. Mount `ios16-root-backup.simg` read-only and extract
   `dyld_shared_cache_arm64e` (`ipsw` is installed on the host).
2. Regenerate `eagl_slots.txt` from 20H392's `OpenGLES.framework` (the dispatch table offsets
   behind `-[EAGLContext getMacroContextPrivate]` almost certainly moved).
3. Find in 20H392's `QuartzCore` the `CA::WindowServer::EAGLServer` vtable slots that
   `inject.c` replaces (`renderer`, `render_update`) and the `EAGLContext` entry points.
4. Port only the GL-relevant part of `inject.c` first; keep the XZ3's existing touch, battery and
   identity work (this tree already has them).
5. Install `/redwood/lib/libredwood-gl.dylib` and inject it into `backboardd`; verify with
   `eagl.c`'s `redwood-gl:` log lines and a frame-rate counter.

### Phase 3 — optional Metal path

dipper also has an AIR → NIR → ir3 frontend (`libredwoodair.dylib`) for CoreAnimation's Metal
renderer. That is a larger project than the GLES path and is not required to get hardware
acceleration: CoreAnimation falls back to its OpenGL ES renderer when Metal has no device.

## XZ3 deltas to keep in mind

| Item | dipper | XZ3 |
| --- | --- | --- |
| panel | 1080×2248 | 1440×2880, DSC command mode |
| presented size | iPhone X-like | 1125×2436 (identity), native 1440×2880 |
| touch | FTS | RMI4 (already working) |
| storage | APFS `darwin` partition | HFS+ in `userdata` |
| boot | UEFI + xnuloader | shim + `fastboot boot` / `boot_a` |
| GPU service | `RedwoodGPU` | `SweetAdreno630` |
| iOS root | 16.5 (20F66) | 16.7.16 (20H392) |
| GPU clock | DCVS in kernel | fixed 257 MHz until DCVS is added |

## Known risks

- **Dyld cache layout** is the main unknown. All dipper address constants are labelled 20F66 and
  must be re-derived; the code checks each before patching, so a mismatch fails closed (no
  acceleration) rather than crashing.
- **OpenGL ES dispatch table** (`eagl_slots.txt`) is build-specific. Using 16.5 offsets on
  20H392 would call the wrong functions; regenerate before loading `libredwood-gl.dylib` into
  `backboardd`.
- **OSMesa ES profile** must satisfy what 16.7's CoreAnimation asks for; `eagl.c` already logs
  every request and has `gltrace*` boot-args for the first failing frame.
- **Kernel ABI coverage**: `gl_test` exercises GEM new/map/submit/wait, but CoreAnimation adds
  IOSurface BOs, relocations and many submits. If the kernel rejects a request, the log will
  name the selector.

## Reproducing the host build

```bash
cd ios-akatsuki
tools/redwood/mk-mesa.sh          # Mesa 25.0.7 -> tools/redwood/build/mesa/out
tools/redwood/build-gl.sh         # -> tools/redwood/out/{libredwood-gl.dylib,gl_test}
```

Both scripts are host-only and never touch a device. `IOS_SDK` selects the SDK
(default `~/ios-sdk/iPhoneOS16.5.sdk`); `MESA_BUILD` relocates the build directory.

## Provenance

Imported from `youzjuzi/dipper-xnu` at `5fcd752` (`patches/xnu-mi8.patch`,
`upstream.lock.json`: HackiOS `8e61187`, userland `906425b`, xnu `c54f35c`). The Mesa patches and
userspace sources are covered by the upstream repository's licences; see its
`LICENSES/`, `THIRD_PARTY_NOTICES.md` and `docs/legal/GPU_LICENSE.md`. This tree only takes the
graphics subset, not the UEFI/APFS stack.
