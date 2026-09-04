#!/bin/zsh
# Regenerates the streaming-decoder fixtures. Requires 7zz (Homebrew "sevenzip").
# The payload is deterministic (seeded), so the archives are reproducible in content
# even though 7zz may write different bytes between versions.
set -e
cd "$(dirname "$0")"
rm -rf src src_big src_tail && mkdir -p src/dir src_big src_tail
python3 - <<'PY'
import random, os
r = random.Random(20260903)
os.chdir("src")
# compressible text with structure (LZ/PPMd friendly)
words = ["page","comic","frame","panel","bubble","ink","tone","spread","右開き","左開き","見開き","ページ"]
for i in range(6):
    with open(f"text_{i:02d}.txt","w") as f:
        for _ in range(600):
            f.write(" ".join(r.choice(words) for _ in range(r.randint(3,12))) + "\n")
# incompressible-ish binary (JPEG-like) of varying sizes
for i in range(6):
    with open(f"dir/blob_{i:02d}.bin","wb") as f:
        f.write(bytes(r.getrandbits(8) for _ in range(r.choice([1, 777, 4096, 20000, 50000, 80000]))))
# fake x86 code: sprinkle E8 call opcodes with small relative offsets (exercises BCJ)
code = bytearray()
for _ in range(30000):
    if r.random() < 0.05:
        code += b"\xE8" + r.randint(-4000, 4000).to_bytes(4, "little", signed=True)
    else:
        code.append(r.getrandbits(8))
open("code.bin","wb").write(code)
# larger fake code (compressible alphabet) so that the streaming filter's 256 KB refill
# boundaries fall inside filtered data several times
big = bytearray(); ops = bytes([0x00,0x48,0x89,0x8B,0x45,0x55,0xC3,0x90,0xE9,0x74,0x75,0x83,0xEC,0x08,0x31,0xFF])
for _ in range(700000):
    if r.random() < 0.04:
        big += b"\xE8" + r.randint(-60000, 60000).to_bytes(4, "little", signed=True)
    else:
        big.append(r.choice(ops))
open("../src_big/code_big.bin","wb").write(big)
# 16-bit PCM-like data with slowly changing values (exercises Delta)
v = 0; pcm = bytearray()
for _ in range(30000):
    v = max(-32000, min(32000, v + r.randint(-40, 40)))
    pcm += v.to_bytes(2, "little", signed=True)
open("wave.pcm","wb").write(pcm)
# filter tails: blocks whose last 256 KB refill leaves fewer bytes than one instruction
# (2 bytes after a 256 KB fill, and 2- / 3-byte blocks). Used with -ms=off so that each
# file is its own block.
arm = bytearray()
while len(arm) < 262146:
    arm += ((0x94000000 | r.getrandbits(16)) if r.random() < 0.2 else r.getrandbits(32)).to_bytes(4, "little")
open("../src_tail/arm_tail.bin","wb").write(arm[:262146])
x86 = bytearray()
while len(x86) < 262146:
    if r.random() < 0.2:
        x86 += b"\xE8" + r.getrandbits(16).to_bytes(4, "little")
    else:
        x86.append(r.getrandbits(8))
open("../src_tail/x86_tail.bin","wb").write(x86[:262146])
open("../src_tail/tiny2.bin","wb").write(bytes([0x94, 0x00]))
open("../src_tail/tiny3.bin","wb").write(bytes([0xE8, 0x01, 0x02]))
open("empty.txt","wb").close()
open("日本語 名前.txt","w").write("日本語の内容\n" * 100)
# manifest: relative path -> sha256, the oracle the tests compare against
import hashlib, json
m = {}
for base in (".", "../src_big", "../src_tail"):
    for root, _, files in os.walk(base):
        for fn in files:
            full = os.path.join(root, fn)
            m[os.path.relpath(full, base)] = hashlib.sha256(open(full, "rb").read()).hexdigest()
json.dump(m, open("../manifest.json", "w"), ensure_ascii=False, indent=1, sort_keys=True)
PY
mk() { local name=$1; shift; rm -f $name.7z; 7zz a -bso0 -bsp0 $name.7z ./src/. "$@"; }
mk lzma2_solid      -m0=lzma2 -ms=on
mk lzma_solid       -m0=lzma  -ms=on
mk ppmd_solid       -m0=ppmd  -ms=on
mk lzma2_nonsolid   -m0=lzma2 -ms=off
mk copy             -mx0
mk delta_lzma2      -mf=delta:2 -ms=on
mk bcj_lzma2        -mf=bcj -ms=on
mk arm64_lzma2      -mf=arm64 -ms=on
mk multiblock       -m0=lzma2 -ms=200k          # several solid blocks
mk bcj2_lzma2       -mf=bcj2 -ms=on             # falls back to the non-streaming path
mk bzip2            -m0=bzip2 -ms=on            # falls back to the non-streaming path
mk deflate          -m0=deflate
mk header_plain     -m0=lzma2 -ms=on -mhc=off   # uncompressed header
mk small_dict       -m0=lzma2 -md=64k -ms=on    # dictionary smaller than the block: SeekBack beyond it must restart
rm -f filter_tail_arm64.7z; 7zz a -bso0 -bsp0 filter_tail_arm64.7z ./src_tail/. -mf=arm64 -ms=off
rm -f filter_tail_bcj.7z;   7zz a -bso0 -bsp0 filter_tail_bcj.7z   ./src_tail/. -mf=bcj   -ms=off
rm -f bcj_boundary.7z; 7zz a -bso0 -bsp0 bcj_boundary.7z ./src_big/. -mf=bcj -ms=on   # filter refill boundaries inside filtered data
rm -rf src src_big src_tail
ls -la *.7z
