"""Make a copy of a Glove80 ZMK .uf2 whose left half never enables USB SOF interrupts.

Equivalent at runtime to building with CONFIG_USB_DEVICE_SOF=n (the upstream ZMK fix,
zmkfirmware/zmk 118359c / PR #3070): in nrfx_usbd_start(enable_sof) the instruction pair
    it eq ; moveq r3, r2      (r3 = mask|SOF unless enable_sof == 0, then r3 = mask)
becomes
    nop   ; mov   r3, r2      (r3 = mask, always)
so INTENSET never gets the SOF bit and the 1 kHz SOF event stream never reaches the
driver's 32-slot event queue.  Only the left-half (family 0x9807B007) image is touched;
every other byte of the file is copied unchanged.

usage: uf2_patch_sof.py <in.uf2> <out.uf2>
"""
import struct
import sys

from capstone import CS_ARCH_ARM, CS_MODE_THUMB, Cs

SRC, DST = sys.argv[1], sys.argv[2]
LEFT_FAMILY = 0x9807B007          # CONFIG_BUILD_OUTPUT_UF2_FAMILY_ID in glove80_lh_defconfig
MASK_BASE = 0x01C01405            # USBRESET|ENDEPIN0|EP0DATADONE|ENDEPOUT0|USBEVENT|EP0SETUP|EPDATA
MASK_SOF = MASK_BASE | (1 << 21)  # + SOF
USBD_BASE = 0x40027000

raw = bytearray(open(SRC, "rb").read())
blocks = []  # (file_offset, addr, size, family)
for off in range(0, len(raw), 512):
    m0, m1, flags, addr, size, bno, nblocks, fam = struct.unpack_from("<8I", raw, off)
    assert m0 == 0x0A324655 and m1 == 0x9E5D5157 and struct.unpack_from("<I", raw, off + 508)[0] == 0x0AB16F30
    assert flags & 0x2000, "family-id flag expected"
    blocks.append((off, addr, size, fam))

fams = sorted({b[3] for b in blocks})
for f in fams:
    bs = [b for b in blocks if b[3] == f]
    print(f"family 0x{f:08x}: {len(bs)} blocks, 0x{min(b[1] for b in bs):08x}-0x{max(b[1] + b[2] for b in bs):08x}")

left = [b for b in blocks if b[3] == LEFT_FAMILY]
lo = min(b[1] for b in left)
hi = max(b[1] + b[2] for b in left)
img = bytearray(b"\xff" * (hi - lo))
where = {}  # image address -> file offset of that byte
for off, addr, size, _ in left:
    img[addr - lo:addr - lo + size] = raw[off + 32:off + 32 + size]
    for i in range(size):
        where[addr + i] = off + 32 + i

u16 = lambda a: struct.unpack_from("<H", img, a - lo)[0]
u32 = lambda a: struct.unpack_from("<I", img, a - lo)[0]
cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB)


def dis(start, end, mark=()):
    for ins in cs.disasm(bytes(img[start - lo:end - lo]), start):
        print(f"    0x{ins.address:08x}: {ins.bytes.hex():<10} {ins.mnemonic:<8} {ins.op_str}{'  <==' if ins.address in mark else ''}")


def lit_hits(val):
    return [lo + i for i in range(0, len(img) - 3, 4) if struct.unpack_from("<I", img, i)[0] == val]


hb, hs = lit_hits(MASK_BASE), lit_hits(MASK_SOF)
print(f"left image: literal mask {[hex(x) for x in hb]}, mask|SOF {[hex(x) for x in hs]}")
assert len(hb) == 1 and len(hs) == 1, "expected exactly one of each literal"
LIT_BASE, LIT_SOF = hb[0], hs[0]


def pc_loads(target):
    out = []
    for pc in range(max(lo, target - 4096), target, 2):
        hw = u16(pc)
        if (hw & 0xF800) == 0x4800 and ((pc + 4) & ~3) + (hw & 0xFF) * 4 == target:
            out.append((pc, (hw >> 8) & 7))
        if hw == 0xF8DF and ((pc + 4) & ~3) + (u16(pc + 2) & 0xFFF) == target:
            out.append((pc, (u16(pc + 2) >> 12) & 0xF))
    return out


lb, ls = pc_loads(LIT_BASE), pc_loads(LIT_SOF)
print(f"loads: mask {[(hex(p), f'r{r}') for p, r in lb]}, mask|SOF {[(hex(p), f'r{r}') for p, r in ls]}")
assert len(lb) == 1 and len(ls) == 1
(pb, rb), (psf, rsf) = lb[0], ls[0]

# Expect, shortly after: cmp r0,#0 ; it eq ; moveq r_sof, r_base ; str.w r_sof,[rX,#0x304]
seq = list(cs.disasm(bytes(img[psf - lo:psf - lo + 24]), psf))
it_ins = next(i for i in seq if i.mnemonic == "it")
mov_ins = seq[seq.index(it_ins) + 1]
str_ins = seq[seq.index(it_ins) + 2]
cmp_ins = seq[seq.index(it_ins) - 1]
print(f"pattern: {cmp_ins.mnemonic} {cmp_ins.op_str} | {it_ins.mnemonic} {it_ins.op_str} | {mov_ins.mnemonic} {mov_ins.op_str} | {str_ins.mnemonic} {str_ins.op_str}")
assert cmp_ins.mnemonic == "cmp" and cmp_ins.op_str == "r0, #0"
assert it_ins.mnemonic == "it" and it_ins.op_str == "eq" and u16(it_ins.address) == 0xBF08
assert mov_ins.mnemonic == "moveq" and mov_ins.op_str == f"r{rsf}, r{rb}"
assert str_ins.mnemonic == "str.w" and str_ins.op_str.startswith(f"r{rsf}, [") and str_ins.op_str.endswith("#0x304]")
# the register used as the USBD base must hold 0x40027000 (INTENSET = base + 0x304)
base_reg = str_ins.op_str.split("[")[1].split(",")[0]
base_loads = [i for i in seq if i.mnemonic == "ldr" and i.op_str.startswith(base_reg + ",")]
assert base_loads, "no load of the USBD base register in the window"
bl_ = base_loads[0]
tgt = ((bl_.address + 4) & ~3) + int(bl_.op_str.split("#")[1].rstrip("]"), 16)
print(f"{base_reg} = [0x{tgt:08x}] = 0x{u32(tgt):08x}")
assert u32(tgt) == USBD_BASE

# Real function entry (loads may be scheduled before the push) and its callers.
fn = psf
while not ((u16(fn) & 0xFF00) == 0xB500 or u16(fn - 2) in (0x4770,) or (u16(fn - 2) & 0xFF00) == 0xBD00):
    fn -= 2
entry = fn
while (u16(entry - 2) & 0xFF00) != 0xBD00 and u16(entry - 2) != 0x4770 and u16(entry - 2) != 0xBF00 and entry > fn - 16:
    entry -= 2
print(f"\nnrfx_usbd_start body (entry ~0x{entry:08x}):")
dis(entry, str_ins.address + 24, mark=(it_ins.address,))


def bl_target(pc):
    h1, h2 = u16(pc), u16(pc + 2)
    if (h1 & 0xF800) != 0xF000 or (h2 & 0xD000) != 0xD000:
        return None
    s = (h1 >> 10) & 1
    i1 = 1 - (((h2 >> 13) & 1) ^ s)
    i2 = 1 - (((h2 >> 11) & 1) ^ s)
    imm = (s << 24) | (i1 << 23) | (i2 << 22) | ((h1 & 0x3FF) << 12) | ((h2 & 0x7FF) << 1)
    return pc + 4 + (imm - (1 << 25) if s else imm)


callers = {}
for cand in range(entry - 8, entry + 6, 2):
    cs_ = [pc for pc in range(lo, hi - 4, 2) if bl_target(pc) == cand]
    if cs_:
        callers[cand] = cs_
print("BL callers:", {hex(k): [hex(c) for c in v] for k, v in callers.items()})
for k, v in callers.items():
    for c in v:
        print(f"  caller 0x{c:08x} -> 0x{k:08x}:")
        dis(c - 16, c + 12, mark=(c,))

# Patch: it eq (0xBF08) -> nop (0xBF00); the following 'mov r3, r2' then always runs.
patch_addr = it_ins.address  # low byte of the halfword holds firstcond/mask
foff = where[patch_addr]
assert raw[foff] == 0x08 and raw[foff + 1] == 0xBF
raw[foff] = 0x00
open(DST, "wb").write(raw)
print(f"\npatched file offset 0x{foff:x} (address 0x{patch_addr:08x}): it eq -> nop; wrote {DST}")

# Verify: re-read, compare byte-for-byte, re-disassemble the patched spot.
new = open(DST, "rb").read()
old = open(SRC, "rb").read()
diff = [i for i in range(len(old)) if old[i] != new[i]]
print(f"bytes differing from the original: {len(diff)} at {[hex(d) for d in diff]}; sizes {len(old)} == {len(new)}")
img[patch_addr - lo] = 0x00
print("patched sequence:")
dis(psf, str_ins.address + 4, mark=(patch_addr,))
