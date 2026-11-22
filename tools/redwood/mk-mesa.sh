#!/bin/bash
# Build Mesa 25.0.7 for the XZ3's iOS userland: the OpenGL ES library behind src/eagl.c
# (see there and src/gl_osmesa.c), with dipper-xnu's patches and the SweetAdreno630 libdrm
# stand-in in mesa/redwood-drm.
#
#   tools/redwood/mk-mesa.sh            build libOSMesa.8.dylib (+ AIR when AIR=1)
#   DRIVERS=softpipe,freedreno          gallium drivers (default: both; softpipe first so the
#                                       probe can prove the build without the GPU)
#
# Cross-compiles from Linux with clang + ld64.lld and the iPhoneOS 16.5 SDK. Output:
# tools/redwood/build/mesa/out/{libOSMesa.8.dylib,exported-gl.txt,gl.xml}.
set -e
VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SDK=${IOS_SDK:-$HOME/ios-sdk/iPhoneOS16.5.sdk}
CC=${CC:-clang}
CXX=${CXX:-clang++}
TARGET=${IOS_TARGET:-arm64-apple-ios16.5}
B=${MESA_BUILD:-$ROOT/build/mesa}
DRIVERS=${DRIVERS:-softpipe,freedreno}
[ -f "$SDK/SDKSettings.json" ] || { echo "mk-mesa.sh: no SDK at $SDK (set IOS_SDK)" >&2; exit 1; }
command -v meson >/dev/null && command -v ninja >/dev/null || {
	echo "mk-mesa.sh: meson and ninja are needed" >&2; exit 1; }

mkdir -p "$B/out"
cd "$B"

# The sources are the release archive's with mesa/*.patch on top. When the patches change the
# tree is thrown away: a build of the old tree would silently be a library that does not match.
PATCHES=$(cat "$ROOT"/mesa/*.patch | sha256sum | cut -d' ' -f1)
if [ ! -d mesa-$VERSION ] || [ "$(cat mesa-$VERSION/.redwood-patches 2>/dev/null)" != "$PATCHES" ]; then
	[ -f mesa-$VERSION.tar.xz ] || curl -sL --fail -o mesa-$VERSION.tar.xz \
		https://archive.mesa3d.org/mesa-$VERSION.tar.xz
	echo "$SHA256  mesa-$VERSION.tar.xz" | sha256sum -c --quiet
	rm -rf mesa-$VERSION build-*
	tar xJf mesa-$VERSION.tar.xz
	for p in "$ROOT"/mesa/*.patch; do
		patch -s --no-backup-if-mismatch -d mesa-$VERSION -p1 < "$p"
	done
	echo "$PATCHES" > mesa-$VERSION/.redwood-patches
fi

# ours, kept in this repository: always the current ones
rm -rf mesa-$VERSION/src/redwood-drm
cp -r "$ROOT/mesa/redwood-drm" mesa-$VERSION/src/redwood-drm
rm -rf mesa-$VERSION/src/compiler/air
cp -r "$ROOT/mesa/air" mesa-$VERSION/src/compiler/air

if [ ! -x venv/bin/python3 ]; then
	python3 -m venv venv
	venv/bin/pip -q install mako pyyaml packaging
fi
export PATH=$B/venv/bin:$PATH

cat > cross.ini <<INI
[binaries]
c = ['$CC', '-target', '$TARGET', '-isysroot', '$SDK', '-fuse-ld=lld']
cpp = ['$CXX', '-target', '$TARGET', '-isysroot', '$SDK', '-fuse-ld=lld', '-fuse-cxa-atexit']
objc = ['$CC', '-target', '$TARGET', '-isysroot', '$SDK', '-fuse-ld=lld']
ar = 'llvm-ar'
ranlib = 'llvm-ranlib'
strip = 'llvm-strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
# meson's cc.has_header_symbol('time.h', 'struct timespec') answers NO when cross-compiling
# (it looks for a preprocessor symbol), so Mesa defines its own struct timespec and collides
# with the SDK's. The SDK has it.
c_args = ['-DHAVE_STRUCT_TIMESPEC']
cpp_args = ['-DHAVE_STRUCT_TIMESPEC']
INI

BUILD=build-${DRIVERS//,/-}
if [ ! -f "$BUILD/build.ninja" ]; then
	meson setup "$BUILD" mesa-$VERSION --cross-file cross.ini --wrap-mode=nofallback \
		--prefix=/redwood --libdir=lib --buildtype=release -Db_ndebug=true \
		-Dplatforms= -Dgallium-drivers="$DRIVERS" -Dfreedreno-kmds=msm \
		-Dvulkan-drivers= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
		-Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled -Dgles1=disabled -Dgles2=enabled \
		-Dopengl=true -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled \
		-Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled \
		-Dvideo-codecs= -Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled \
		-Dgallium-xa=disabled -Dlmsensors=disabled -Dbuild-tests=false > meson-setup.log
fi
ninja -C "$BUILD" > ninja.log

if [ "${AIR:-}" = 1 ]; then
	ninja -C "$BUILD" src/gallium/drivers/freedreno/air_run >> ninja.log
	cp "$BUILD/src/gallium/drivers/freedreno/air_run" out/air_run
	ninja -C "$BUILD" src/gallium/drivers/freedreno/libredwoodair.dylib >> ninja.log
	llvm-strip -x -o out/libredwoodair.dylib "$BUILD/src/gallium/drivers/freedreno/libredwoodair.dylib"
	install_name_tool -id /redwood/lib/libredwoodair.dylib out/libredwoodair.dylib
	cat "$ROOT"/mesa/air/* | sha256sum > out/built-from-air
fi

llvm-strip -x -o out/libOSMesa.8.dylib "$BUILD/src/gallium/targets/osmesa/libOSMesa.8.dylib"
install_name_tool -id /redwood/lib/libOSMesa.8.dylib out/libOSMesa.8.dylib
nm -gU out/libOSMesa.8.dylib | awk '$3 ~ /^_gl/ { print substr($3, 2) }' > out/exported-gl.txt
cp mesa-$VERSION/src/mapi/glapi/registry/gl.xml out/gl.xml
echo "mk-mesa.sh: $B/out/libOSMesa.8.dylib ($(stat -c %s out/libOSMesa.8.dylib) bytes, $(wc -l < out/exported-gl.txt) gl* entries)"
