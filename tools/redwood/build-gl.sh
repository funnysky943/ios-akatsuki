#!/bin/bash
# Build the userspace half of the ported dipper GPU stack for the XZ3:
#
#   libredwood-gl.dylib   EAGL/OpenGL ES implementation (src/eagl.c + src/gl_osmesa.c) behind
#                         Mesa's OSMesa, install name /redwood/lib/libredwood-gl.dylib
#   gl_test               standalone renderer/readback probe (no window server, no panel)
#
# Run tools/redwood/mk-mesa.sh first. This script is host-only; it never talks to the phone.
set -e
ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SDK=${IOS_SDK:-$HOME/ios-sdk/iPhoneOS16.5.sdk}
CC=${CC:-clang}
TARGET=${IOS_TARGET:-arm64-apple-ios16.5}
M=${MESA_BUILD:-$ROOT/build/mesa}
OUT=$ROOT/out
FLAGS=(-target "$TARGET" -isysroot "$SDK" -O2 -fuse-ld=lld)

[ -f "$M/out/libOSMesa.8.dylib" ] || { echo "build-gl.sh: run mk-mesa.sh first (no $M/out/libOSMesa.8.dylib)" >&2; exit 1; }
mkdir -p "$OUT" "$OUT/obj"

python3 "$ROOT/src/mkeagl.py" "$ROOT/src/eagl_slots.txt" "$M/out/gl.xml" "$M/out/exported-gl.txt" \
	"$ROOT/src/eagl.c" > "$OUT/obj/eagl_gen.h"

"$CC" "${FLAGS[@]}" -I"$ROOT/src" -I"$OUT/obj" -dynamiclib \
	-install_name /redwood/lib/libredwood-gl.dylib \
	-framework CoreFoundation -framework IOKit -framework IOSurface -lobjc \
	"$ROOT/src/eagl.c" "$ROOT/src/gl_osmesa.c" "$M/out/libOSMesa.8.dylib" \
	-o "$OUT/libredwood-gl.dylib"

"$CC" "${FLAGS[@]}" -I"$ROOT/src" \
	"$ROOT/src/gl_test.c" "$M/out/libOSMesa.8.dylib" -o "$OUT/gl_test"

cp -f "$M/out/libOSMesa.8.dylib" "$OUT/"
echo "build-gl.sh:"
ls -l "$OUT/libredwood-gl.dylib" "$OUT/libOSMesa.8.dylib" "$OUT/gl_test"
