#!/usr/bin/env python3
"""
Minimal RV32I assembler + instruction-set simulator.

The openPCIE UVM environment needs a firmware image for the PicoRV32 inside
`riscv_pcie_soc`, because the DUT does an unconditional
`$readmemh("firmware.hex", ram)`.  No RISC-V toolchain is assumed to be
present, so this module supplies both:

  * `assemble()` - two-pass assembler covering the RV32I subset the mailbox
    firmware uses (lui/addi/add/sub/and/or/xor/lw/sw/beq/bne/jal/jalr + a few
    pseudo-ops).
  * `RV32Sim`   - a cycle-agnostic ISS with a pluggable MMIO callback, used to
    execute the firmware against a Python model of the bridge before the image
    is ever handed to a simulator.

Keeping the ISS here means the firmware is verified on this machine rather
than debugged inside a UVM regression.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# --------------------------------------------------------------------------
# Register names
# --------------------------------------------------------------------------

ABI = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9, "a0": 10, "a1": 11, "a2": 12, "a3": 13,
    "a4": 14, "a5": 15, "a6": 16, "a7": 17, "s2": 18, "s3": 19, "s4": 20,
    "s5": 21, "s6": 22, "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
}


class AsmError(Exception):
    pass


def _reg(tok: str) -> int:
    t = tok.strip().lower()
    if t in ABI:
        return ABI[t]
    if re.fullmatch(r"x([0-9]|[12][0-9]|3[01])", t):
        return int(t[1:])
    raise AsmError(f"bad register '{tok}'")


def _imm(tok: str, labels: dict[str, int] | None = None) -> int:
    t = tok.strip()
    if labels is not None and t in labels:
        return labels[t]
    try:
        return int(t, 0)
    except ValueError as exc:
        raise AsmError(f"bad immediate '{tok}'") from exc


def _sx(val: int, bits: int) -> int:
    """Sign-extend `bits`-wide `val` to a Python int."""
    m = 1 << (bits - 1)
    return (val & ((1 << bits) - 1)) - ((val & m) << 1)


def _fits(val: int, bits: int) -> bool:
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return lo <= val <= hi


# --------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------

def _r(op, f3, f7, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _i(op, f3, rd, rs1, imm):
    if not _fits(imm, 12):
        raise AsmError(f"I-type immediate {imm} out of range (-2048..2047)")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s(op, f3, rs1, rs2, imm):
    if not _fits(imm, 12):
        raise AsmError(f"S-type immediate {imm} out of range (-2048..2047)")
    i = imm & 0xFFF
    return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
        | ((i & 0x1F) << 7) | op


def _b(op, f3, rs1, rs2, off):
    if off & 1:
        raise AsmError("branch target must be 2-byte aligned")
    if not _fits(off, 13):
        raise AsmError(f"branch offset {off} out of range")
    i = off & 0x1FFF
    return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (rs2 << 20) \
        | (rs1 << 15) | (f3 << 12) | (((i >> 1) & 0xF) << 8) \
        | (((i >> 11) & 1) << 7) | op


def _u(op, rd, imm):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | op


def _j(op, rd, off):
    if off & 1:
        raise AsmError("jump target must be 2-byte aligned")
    if not _fits(off, 21):
        raise AsmError(f"jal offset {off} out of range")
    i = off & 0x1FFFFF
    return (((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) \
        | (((i >> 11) & 1) << 20) | (((i >> 12) & 0xFF) << 12) | (rd << 7) | op


OP_R, OP_I, OP_LD, OP_ST, OP_BR, OP_LUI, OP_AUIPC, OP_JAL, OP_JALR = (
    0x33, 0x13, 0x03, 0x23, 0x63, 0x37, 0x17, 0x6F, 0x67)

R_OPS = {"add": (0, 0), "sub": (0, 0x20), "sll": (1, 0), "slt": (2, 0),
         "sltu": (3, 0), "xor": (4, 0), "srl": (5, 0), "sra": (5, 0x20),
         "or": (6, 0), "and": (7, 0)}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SH_OPS = {"slli": (1, 0), "srli": (5, 0), "srai": (5, 0x20)}
LD_OPS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
ST_OPS = {"sb": 0, "sh": 1, "sw": 2}
BR_OPS = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}

_MEM_RE = re.compile(r"^\s*(-?\w+)\s*\(\s*(\w+)\s*\)\s*$")


# --------------------------------------------------------------------------
# Assembler
# --------------------------------------------------------------------------

def assemble(text: str, base: int = 0) -> tuple[list[int], dict[str, int]]:
    """Assemble `text`; return (word list, label map). `base` is the load PC."""
    raw = []
    for lineno, line in enumerate(text.splitlines(), 1):
        line = re.sub(r"[#;].*$", "", line).strip()
        while line:
            m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*", line)
            if not m:
                break
            raw.append((lineno, ("label", m.group(1))))
            line = line[m.end():].strip()
        if line:
            raw.append((lineno, ("insn", line)))

    # Pass 1 - assign addresses. Every real instruction is 4 bytes; `li`
    # expands to 1 or 2 depending on the value, so it must be sized here.
    labels: dict[str, int] = {}
    sized: list[tuple[int, str, int]] = []      # (lineno, text, addr)
    pc = base
    for lineno, (kind, body) in raw:
        if kind == "label":
            if body in labels:
                raise AsmError(f"line {lineno}: duplicate label '{body}'")
            labels[body] = pc
            continue
        sized.append((lineno, body, pc))
        pc += 4 * _insn_words(body)

    # Pass 2 - encode.
    words: list[int] = []
    for lineno, body, addr in sized:
        try:
            words.extend(_encode(body, addr, labels))
        except AsmError as exc:
            raise AsmError(f"line {lineno}: {exc}  |  {body}") from None
    return words, labels


def _split(body: str) -> tuple[str, list[str]]:
    parts = body.split(None, 1)
    mnem = parts[0].lower()
    args = [a.strip() for a in parts[1].split(",")] if len(parts) > 1 else []
    return mnem, args


# Directives that carry no code and are simply consumed.
_IGNORED_DIRECTIVES = {".text", ".data", ".section", ".globl", ".global",
                       ".type", ".size", ".align", ".p2align", ".option",
                       ".file", ".ident", ".attribute"}


def _insn_words(body: str) -> int:
    mnem, args = _split(body)
    if mnem in _IGNORED_DIRECTIVES:
        return 0
    if mnem == ".word":
        return len(args)
    if mnem == "li":
        v = _imm(args[1])
        return 1 if _fits(v, 12) else 2
    if mnem in ("nop", "j", "mv", "not", "neg", "beqz", "bnez", "ret"):
        return 1
    return 1


def _encode(body: str, addr: int, labels: dict[str, int]) -> list[int]:
    mnem, a = _split(body)

    # ---- directives -----------------------------------------------------
    if mnem in _IGNORED_DIRECTIVES:
        return []
    if mnem == ".word":
        return [_imm(x, labels) & 0xFFFFFFFF for x in a]

    # ---- pseudo-instructions -------------------------------------------
    if mnem == "nop":
        return [_i(OP_I, 0, 0, 0, 0)]
    if mnem == "ret":
        return [_i(OP_JALR, 0, 0, 1, 0)]
    if mnem == "mv":
        return [_i(OP_I, 0, _reg(a[0]), _reg(a[1]), 0)]
    if mnem == "not":
        return [_i(OP_I, 4, _reg(a[0]), _reg(a[1]), -1)]
    if mnem == "neg":
        return [_r(OP_R, 0, 0x20, _reg(a[0]), 0, _reg(a[1]))]
    if mnem == "j":
        return [_j(OP_JAL, 0, _imm(a[0], labels) - addr)]
    if mnem == "beqz":
        return [_b(OP_BR, 0, _reg(a[0]), 0, _imm(a[1], labels) - addr)]
    if mnem == "bnez":
        return [_b(OP_BR, 1, _reg(a[0]), 0, _imm(a[1], labels) - addr)]
    if mnem == "li":
        rd, v = _reg(a[0]), _imm(a[1], labels)
        if _fits(v, 12):
            return [_i(OP_I, 0, rd, 0, v)]
        # lui/addi pair, compensating for addi's sign extension
        lo = _sx(v & 0xFFF, 12)
        hi = ((v - lo) >> 12) & 0xFFFFF
        return [_u(OP_LUI, rd, hi), _i(OP_I, 0, rd, rd, lo)]

    # ---- real instructions ---------------------------------------------
    if mnem in R_OPS:
        f3, f7 = R_OPS[mnem]
        return [_r(OP_R, f3, f7, _reg(a[0]), _reg(a[1]), _reg(a[2]))]
    if mnem in I_OPS:
        return [_i(OP_I, I_OPS[mnem], _reg(a[0]), _reg(a[1]),
                   _imm(a[2], labels))]
    if mnem in SH_OPS:
        f3, f7 = SH_OPS[mnem]
        sh = _imm(a[2]) & 0x1F
        return [_i(OP_I, f3, _reg(a[0]), _reg(a[1]), (f7 << 5) | sh)]
    if mnem in LD_OPS or mnem in ST_OPS:
        m = _MEM_RE.match(a[1])
        if not m:
            raise AsmError(f"expected 'offset(reg)', got '{a[1]}'")
        off, rs1 = _imm(m.group(1), labels), _reg(m.group(2))
        if mnem in LD_OPS:
            return [_i(OP_LD, LD_OPS[mnem], _reg(a[0]), rs1, off)]
        return [_s(OP_ST, ST_OPS[mnem], rs1, _reg(a[0]), off)]
    if mnem in BR_OPS:
        return [_b(OP_BR, BR_OPS[mnem], _reg(a[0]), _reg(a[1]),
                   _imm(a[2], labels) - addr)]
    if mnem == "lui":
        return [_u(OP_LUI, _reg(a[0]), _imm(a[1], labels))]
    if mnem == "auipc":
        return [_u(OP_AUIPC, _reg(a[0]), _imm(a[1], labels))]
    if mnem == "jal":
        if len(a) == 1:
            return [_j(OP_JAL, 1, _imm(a[0], labels) - addr)]
        return [_j(OP_JAL, _reg(a[0]), _imm(a[1], labels) - addr)]
    if mnem == "jalr":
        if len(a) == 1:
            return [_i(OP_JALR, 0, 1, _reg(a[0]), 0)]
        m = _MEM_RE.match(a[1])
        if m:
            return [_i(OP_JALR, 0, _reg(a[0]), _reg(m.group(2)),
                       _imm(m.group(1), labels))]
        return [_i(OP_JALR, 0, _reg(a[0]), _reg(a[1]), _imm(a[2], labels))]

    raise AsmError(f"unsupported mnemonic '{mnem}'")


# --------------------------------------------------------------------------
# Instruction-set simulator
# --------------------------------------------------------------------------

@dataclass
class RV32Sim:
    """RV32I ISS with a word-addressed RAM and an MMIO hook.

    `mmio_read(addr) -> int` and `mmio_write(addr, value)` are invoked for any
    access outside the RAM window, mirroring the DUT's address decode
    (`is_ram = addr[31:24] == 0x00`).
    """

    ram_words: int = 2048
    pc: int = 0
    regs: list[int] = field(default_factory=lambda: [0] * 32)
    ram: list[int] = field(default_factory=list)
    mmio_read: object = None
    mmio_write: object = None
    retired: int = 0
    trap: str | None = None

    def __post_init__(self):
        if not self.ram:
            self.ram = [0] * self.ram_words

    def load(self, words: list[int], at_word: int = 0) -> None:
        for k, w in enumerate(words):
            self.ram[at_word + k] = w & 0xFFFFFFFF

    # -- memory ----------------------------------------------------------
    def _is_ram(self, addr: int) -> bool:
        return (addr >> 24) & 0xFF == 0x00

    def read32(self, addr: int) -> int:
        if self._is_ram(addr):
            idx = (addr >> 2) & 0x7FF          # DUT indexes ram[addr[12:2]]
            return self.ram[idx] & 0xFFFFFFFF
        if self.mmio_read:
            return self.mmio_read(addr) & 0xFFFFFFFF
        return 0xDEADBEEF                      # DUT default for unmapped

    def write32(self, addr: int, val: int, strb: int = 0xF) -> None:
        val &= 0xFFFFFFFF
        if self._is_ram(addr):
            idx = (addr >> 2) & 0x7FF
            old = self.ram[idx]
            new = 0
            for b in range(4):
                sh = b * 8
                new |= ((val if (strb >> b) & 1 else old) & (0xFF << sh))
            self.ram[idx] = new & 0xFFFFFFFF
        elif self.mmio_write:
            self.mmio_write(addr, val, strb)

    # -- execution -------------------------------------------------------
    def _wr(self, rd: int, val: int) -> None:
        if rd:
            self.regs[rd] = val & 0xFFFFFFFF

    def step(self) -> None:
        insn = self.read32(self.pc)
        op = insn & 0x7F
        rd = (insn >> 7) & 0x1F
        f3 = (insn >> 12) & 7
        rs1 = (insn >> 15) & 0x1F
        rs2 = (insn >> 20) & 0x1F
        f7 = (insn >> 25) & 0x7F
        x1 = self.regs[rs1]
        x2 = self.regs[rs2]
        nxt = self.pc + 4

        if op == OP_LUI:
            self._wr(rd, insn & 0xFFFFF000)
        elif op == OP_AUIPC:
            self._wr(rd, self.pc + (insn & 0xFFFFF000))
        elif op == OP_JAL:
            off = _sx((((insn >> 31) & 1) << 20) | (((insn >> 21) & 0x3FF) << 1)
                      | (((insn >> 20) & 1) << 11)
                      | (((insn >> 12) & 0xFF) << 12), 21)
            self._wr(rd, nxt)
            nxt = (self.pc + off) & 0xFFFFFFFF
        elif op == OP_JALR:
            off = _sx(insn >> 20, 12)
            self._wr(rd, nxt)
            nxt = (x1 + off) & 0xFFFFFFFE
        elif op == OP_BR:
            off = _sx((((insn >> 31) & 1) << 12) | (((insn >> 25) & 0x3F) << 5)
                      | (((insn >> 8) & 0xF) << 1) | (((insn >> 7) & 1) << 11), 13)
            s1, s2 = _sx(x1, 32), _sx(x2, 32)
            take = {0: x1 == x2, 1: x1 != x2, 4: s1 < s2, 5: s1 >= s2,
                    6: x1 < x2, 7: x1 >= x2}[f3]
            if take:
                nxt = (self.pc + off) & 0xFFFFFFFF
        elif op == OP_LD:
            addr = (x1 + _sx(insn >> 20, 12)) & 0xFFFFFFFF
            w = self.read32(addr & ~3)
            if f3 == 2:
                self._wr(rd, w)
            elif f3 in (0, 4):
                b = (w >> ((addr & 3) * 8)) & 0xFF
                self._wr(rd, b if f3 == 4 else _sx(b, 8))
            else:
                h = (w >> ((addr & 2) * 8)) & 0xFFFF
                self._wr(rd, h if f3 == 5 else _sx(h, 16))
        elif op == OP_ST:
            off = _sx((f7 << 5) | rd, 12)
            addr = (x1 + off) & 0xFFFFFFFF
            if f3 == 2:
                self.write32(addr, x2, 0xF)
            elif f3 == 0:
                sh = (addr & 3) * 8
                self.write32(addr & ~3, (x2 & 0xFF) << sh, 1 << (addr & 3))
            else:
                sh = (addr & 2) * 8
                self.write32(addr & ~3, (x2 & 0xFFFF) << sh,
                             0x3 << (addr & 2))
        elif op in (OP_I, OP_R):
            b = x2 if op == OP_R else _sx(insn >> 20, 12) & 0xFFFFFFFF
            sh = (b & 0x1F)
            if f3 == 0:
                r = x1 - b if (op == OP_R and f7 == 0x20) else x1 + b
            elif f3 == 1:
                r = x1 << sh
            elif f3 == 2:
                r = 1 if _sx(x1, 32) < _sx(b, 32) else 0
            elif f3 == 3:
                r = 1 if x1 < (b & 0xFFFFFFFF) else 0
            elif f3 == 4:
                r = x1 ^ b
            elif f3 == 5:
                r = (_sx(x1, 32) >> sh) if f7 == 0x20 else ((x1 & 0xFFFFFFFF) >> sh)
            elif f3 == 6:
                r = x1 | b
            else:
                r = x1 & b
            self._wr(rd, r)
        else:
            self.trap = f"illegal opcode 0x{op:02x} (insn 0x{insn:08x}) at pc 0x{self.pc:08x}"
            return

        self.pc = nxt & 0xFFFFFFFF
        self.retired += 1

    def run(self, max_insn: int = 100_000) -> None:
        for _ in range(max_insn):
            self.step()
            if self.trap:
                raise RuntimeError(self.trap)


def to_hex(words: list[int], depth: int) -> str:
    """Render `words` as a $readmemh image of exactly `depth` lines."""
    if len(words) > depth:
        raise AsmError(f"image is {len(words)} words, RAM holds {depth}")
    out = [f"{w & 0xFFFFFFFF:08x}" for w in words]
    out += ["00000000"] * (depth - len(words))
    return "\n".join(out) + "\n"
