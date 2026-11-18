#!/usr/bin/env python3
# Symbolicate one process from a SWEET stack sample (SMP lines, sweetsample=):
#   tools/smp-sym.py CLEAN_LOG PROCESS SAMPLE_NO
#
# Needs research/dsc/dyld_shared_cache_arm64 and a patched ipsw that tolerates
# the missing .symbols member (IPSW=/path/to/ipsw-patched). Local symbols are
# not available on-device, so names are export symbols (or func_XXX) plus the
# containing image and offset, which is enough to read a stalled stack.
import bisect, os, re, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.realpath(os.path.join(HERE, '..', 'research', 'dsc', 'dyld_shared_cache_arm64'))
IPSW = os.environ.get('IPSW', '/home/sky/ipsw-patched')

L, want, sample = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(L).read()
blk = text.split('SMP --- sample %s' % sample, 1)[1]
blk = re.split(r'SMP --- sample |SMP: DELAY', blk, maxsplit=1)[0]
ents = ['SMP ' + e for e in blk.replace('\n', ' ').split('SMP ') if e.strip()]
slide = None
threads = []
for e in ents:
    m = re.match(r'SMP (\S+)\[(\d+)\] slide (0x[0-9a-f]+)', e)
    if m and m.group(1) == want:
        slide = int(m.group(3), 16)
        continue
    m = re.match(r'SMP (\S+) t(\d+) pc (0x[0-9a-f]+) lr (0x[0-9a-f]+) sp \S+ bt(.*)', e)
    if m and m.group(1) == want:
        bt = [int(x, 16) for x in re.findall(r'0x[0-9a-f]{6,}', m.group(5))]
        threads.append((int(m.group(2)), [int(m.group(3), 16), int(m.group(4), 16)] + bt))
if slide is None:
    sys.exit('%s not in sample %s' % (want, sample))

# Image table of the primary cache: unslid load address -> path.
with open(CACHE, 'rb') as f:
    h = f.read(0x400)
    io, ic = struct.unpack_from('<II', h, 0x1c0)
    f.seek(io)
    raw = f.read(ic * 32)
imgs = [struct.unpack_from('<QQQII', raw, i * 32) for i in range(ic)]
bases = [i[0] for i in imgs]


def image_of(unslid):
    k = bisect.bisect_right(bases, unslid) - 1
    if k < 0:
        return None, 0
    with open(CACHE, 'rb') as f:
        f.seek(imgs[k][3])
        path = f.read(160).split(b'\0')[0].decode('utf8', 'replace')
    return path, unslid - imgs[k][0]


cache = {}


def sym(a):
    if a in cache:
        return cache[a]
    unslid = a - slide
    m = subprocess.run([IPSW, 'dyld', 'a2s', CACHE, hex(unslid)], capture_output=True, text=True)
    hit = [l for l in m.stdout.splitlines() if l.startswith('0x')]
    name = hit[-1].split(': ', 1)[1][:120] if hit else '?'
    path, off = image_of(unslid)
    cache[a] = '%s  [%s+%#x]' % (name, os.path.basename(path or '?'), off)
    return cache[a]


print(want, 'slide', hex(slide), len(threads), 'threads')
for tid, addrs in threads:
    print('-- t%d' % tid)
    for a in addrs[:16]:
        print('   ', hex(a), sym(a))
