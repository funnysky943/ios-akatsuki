#!/bin/bash
# Add the ported dipper GPU userspace to an existing raw iOS root image.
#
#   sudo tools/redwood/install-into-image.sh ROOT.img
#
# ROOT.img must be the raw HFS+ image (convert an Android sparse image with simg2img first).
# The image is mounted read-write for the duration; nothing here touches a device.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${1:?usage: install-into-image.sh ROOT.img}
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }
[[ -f $IMG ]] || { echo "no such image: $IMG" >&2; exit 1; }

for f in libOSMesa.8.dylib libredwood-gl.dylib gl_test; do
	[[ -f $HERE/out/$f ]] || { echo "missing $HERE/out/$f; run tools/redwood/build-gl.sh" >&2; exit 1; }
done

mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
mount -o loop,force "$IMG" "$mnt"

install -d -o 0 -g 0 "$mnt/redwood/lib" "$mnt/usr/local/bin"
install -m 0644 -o 0 -g 0 "$HERE/out/libOSMesa.8.dylib" "$mnt/redwood/lib/libOSMesa.8.dylib"
install -m 0644 -o 0 -g 0 "$HERE/out/libredwood-gl.dylib" "$mnt/redwood/lib/libredwood-gl.dylib"
install -m 0755 -o 0 -g 0 "$HERE/out/gl_test" "$mnt/usr/local/bin/gl_test"
install -m 0644 -o 0 -g 0 "$HERE/gltest.plist" "$mnt/Library/LaunchDaemons/org.redwood.gltest.plist"

sync
umount "$mnt"
trap - EXIT
rmdir "$mnt"
echo "installed into $IMG:"
echo "  /redwood/lib/libOSMesa.8.dylib"
echo "  /redwood/lib/libredwood-gl.dylib"
echo "  /usr/local/bin/gl_test"
echo "  /Library/LaunchDaemons/org.redwood.gltest.plist"
echo "boot with adreno=9 zap=1 gpuhold=1; result is in the persistent log and /tmp/gl_test.ppm"
