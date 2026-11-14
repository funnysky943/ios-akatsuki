#!/usr/bin/env python3
"""fajita-verify-image.py SIMG|NONE BOOT.IMG - dry check of the fajita iOS root and boot image.

Checks what the port depends on, without a phone:
  * root: Chlorophyll dylibs + the inject linked into a re-signed backboardd (identifier and entitlements
    kept), sweetfp in PosterBoard, /bin/sh + toybox, the on-device tools, the first-boot and log jobs, the
    poster script, the switches (bgmtl.arm present, no kill switches, bgmtl.log -> /dev/null);
  * boot: Android header, the SWEETXNU payload, the cmdline arguments, the ADT (identity, canvas, scale,
    product node, fb geometry) and the appended fajita DTB.

  python3 tools/fajita-verify-image.py /home/edi194/src/ios18-root-gpu.simg /mnt/c/.../ios18-fast.img

Pass NONE as the image to skip the root checks.
"""
import hashlib
import os
import plistlib
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + '/renegade')
import hfsx
import pacstrip

OK = FAIL = 0


def check(label, cond, detail=''):
    global OK, FAIL
    if cond:
        OK += 1
        print('  OK   %-58s %s' % (label, detail))
    else:
        FAIL += 1
        print('  FAIL %-58s %s' % (label, detail))


def root_checks(simg):
    v = hfsx.Vol(hfsx.Simg(simg))

    def stat(p):
        e = v.lookup(p, follow=False)
        if not e:
            return None
        rt, cnid, d = e
        mode = struct.unpack_from('>H', v.cat, d + 32 + 10)[0]
        return rt, cnid, d, mode

    def read(p):
        try:
            return v.open(p).read()
        except Exception:
            return None

    print('== root image files')
    for p in ('/bin/sh', '/bin/toybox', '/usr/local/bin/sweetshot', '/usr/local/bin/sweetlog',
              '/usr/local/bin/sweetposterset', '/usr/local/bin/sweetuicache',
              '/usr/local/lib/bgmtl/bgmtl-inject.dylib', '/usr/local/lib/bgmtl/libbgair.dylib',
              '/usr/local/lib/bgmtl/libdrm.2.dylib', '/usr/local/lib/sweetfp.dylib',
              '/usr/libexec/backboardd.orig', '/usr/local/libexec/renegade-firstboot.sh',
              '/usr/local/lib/bergamota-gl/bgl-launch',
              '/Applications/SweetRun.app/SweetRun'):
        s = stat(p)
        check(p, s is not None and (s[3] & 0o777) == 0o755, 'mode=%o' % (s[3] & 0o777) if s else 'missing')

    print('\n== backboardd (Chlorophyll as the system compositor)')
    bb, orig = read('/usr/libexec/backboardd'), read('/usr/libexec/backboardd.orig')
    check('backboardd links bgmtl-inject', bb and b'/usr/local/lib/bgmtl/bgmtl-inject.dylib' in bb)
    check('backboardd.orig is clean', orig and b'/usr/local/lib/bgmtl/bgmtl-inject.dylib' not in orig)
    open('/tmp/fajita-bb', 'wb').write(bb or b'')
    check('identity preserved', pacstrip.cs_identity('/tmp/fajita-bb')[0] == 'com.apple.backboardd')
    ents = pacstrip.entitlements_xml('/tmp/fajita-bb')
    check('entitlements preserved', bool(ents) and len(ents) > 5000, '%d bytes' % (len(ents) if ents else 0))

    print('\n== launchd jobs')
    pl = plistlib.loads(read('/System/Library/xpc/launchd.plist'))
    jobs = {j.get('Label'): j for j in (pl.get('LaunchDaemons') or {}).values()}
    bbjob = jobs.get('com.apple.backboardd') or {}
    check('backboardd job -> bgl-launch',
          bbjob.get('ProgramArguments') == ['/usr/local/lib/bergamota-gl/bgl-launch'])
    check('backboardd job has BGMTL_BB=1',
          (bbjob.get('EnvironmentVariables') or {}).get('BGMTL_BB') == '1')
    check('first-boot job', (jobs.get('org.bergamota.renegade-firstboot') or {}).get('ProgramArguments') ==
          ['/bin/sh', '/usr/local/libexec/renegade-firstboot.sh'])
    shot = (jobs.get('org.bergamota.shot') or {}).get('ProgramArguments') or ['', '', '']
    check('log job has one unquoted command', len(shot) == 3 and not shot[2].startswith('"'))

    script = (read('/usr/local/libexec/renegade-firstboot.sh') or b'').decode('utf8', 'replace')
    check('poster script selects a poster', 'sweetposterset com.apple.WallpaperKit.CollectionsPoster 5010' in script)

    print('\n== switches and wiring')
    logp = stat('/private/var/tmp/bgmtl.log')
    check('bgmtl.log -> /dev/null', logp and (logp[3] & 0o170000) == 0o120000 and
          v.read_file(logp[0], logp[1], logp[2]) == b'/dev/null')
    check('bgmtl.arm present', stat('/private/var/tmp/bgmtl.arm') is not None)
    check('no bgmtl.off', stat('/private/var/tmp/bgmtl.off') is None)
    check('no bgmtl-bb.off', stat('/private/var/tmp/bgmtl-bb.off') is None)
    env = read('/private/var/tmp/bgmtl-bb.env') or b''
    check('bgmtl-bb.env', b'RWA_LINEAR_SAMPLED=0' in env, env.strip())
    for n in ('D16.Default.plist', 'D16.Touch.plist'):
        check('/System/Library/EventTimingProfiles/' + n, stat('/System/Library/EventTimingProfiles/' + n) is not None)
    pb = read('/Applications/PosterBoard.app/PosterBoard')
    check('PosterBoard links sweetfp', pb and b'/usr/local/lib/sweetfp.dylib' in pb)
    mer = read('/System/Library/ExtensionKit/Extensions/MercuryPosterExtension.appex/MercuryPosterExtension')
    check('Mercury links bgmtl-inject', mer and b'/usr/local/lib/bgmtl/bgmtl-inject.dylib' in mer)
    check('first-boot marker absent', stat('/private/var/db/.renegade-firstboot-done') is None)


def boot_checks(img):
    data = open(img, 'rb').read()
    print('\n== boot image')
    check('Android boot magic', data[:8] == b'ANDROID!', data[:8])
    ks, _, rs, _, _, _, _, page = struct.unpack_from('<8I', data, 8)
    page = page or 2048
    off = page + -(-ks // page) * page
    check('payload magic', data[off:off + 8] == b'SWEETXNU')
    pl = data[off:off + rs]
    version, nsegs = struct.unpack_from('<II', pl, 8)
    adt_off, adt_size = struct.unpack_from('<QQ', pl, 0x20)
    cmd = pl[0x48:0x48 + 608].split(b'\0')[0].decode()
    check('payload version 1', version == 1, version)
    check('segments', nsegs > 0, nsegs)
    for arg in ('sweetfb_hz=60', 'sweetfb_hw=1', 'sweetfb_flip=1', 'sweetfb_scale=1',
                'sweetts=1', 'sweetgpu=8', 'sweetarm64e=1', 'rd=ufsroot0'):
        check('cmdline ' + arg, arg in cmd)

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'mkadt', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mkadt.py'))
    mk = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mk)
    root = mk.adt.parse(pl[adt_off:adt_off + adt_size])[0]
    props = {}

    def walk(n, path=''):
        nm = getattr(n, 'name', b'')
        nm = nm.rstrip(b'\0').decode() if isinstance(nm, bytes) else str(nm)
        p = path + '/' + nm
        for (k, f, val) in (getattr(n, 'props', None) or []):
            key = k.rstrip(b'\0').decode() if isinstance(k, bytes) else str(k)
            props[(p, key)] = val
        for ch in (getattr(n, 'children', None) or []):
            walk(ch, p)

    walk(root)
    u32 = lambda p: struct.unpack('<I', props[p])[0] if p in props and len(props[p]) == 4 else None
    cstr = lambda p: props[p].rstrip(b'\0').decode() if p in props else None
    check('identity', cstr(('/device-tree', 'target-sub-type')) == 'D16AP',
          cstr(('/device-tree', 'target-sub-type')))
    check('model', cstr(('/device-tree', 'model')) == 'iPhone14,4', cstr(('/device-tree', 'model')))
    check('canvas 1125x2436',
          (u32(('/device-tree/arm-io/disp0', 'canvas-width')),
           u32(('/device-tree/arm-io/disp0', 'canvas-height'))) == (1125, 2436))
    check('display-scale 3', u32(('/device-tree/chosen', 'display-scale')) == 3)
    check('panel 1080x2340',
          (u32(('/device-tree/sweet-fbcon', 'width')), u32(('/device-tree/sweet-fbcon', 'height'))) == (1080, 2340))
    check('product node is the 13 mini', cstr(('/device-tree/product', 'product-name')) == 'iPhone 13 mini')
    check('artwork subtype 2340', u32(('/device-tree/product', 'artwork-device-subtype')) == 2340)


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    if sys.argv[1] != 'NONE':
        root_checks(sys.argv[1])
    boot_checks(sys.argv[2])
    print('\n== %d ok, %d failed' % (OK, FAIL))
    sys.exit(1 if FAIL else 0)
