#!/usr/bin/env python3
"""
Static consistency checks for the openPCIE UVM testbench.

No simulator required.  Catches the class of mistake that would otherwise cost
a compile-debug round trip on VCS/Xcelium:

  * filelist entries that do not resolve to a file
  * `include directives with no matching file on the include path
  * DUT port list in tb_top vs the actual RTL module declaration
  * mailbox constants disagreeing between the firmware, its build script and
    openpcie_types_pkg.sv
  * bridge register offsets disagreeing between the RTL, the types package and
    the RAL

Exit 0 clean, 1 on findings.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL_SOC = ROOT / "rtl" / "openPCIE" / "2.rtl" / "2.RC-direct.opensource" / "src" / "riscv_pcie_soc.sv"
findings: list[str] = []
checks = 0


def check(cond: bool, msg: str) -> None:
    global checks
    checks += 1
    if not cond:
        findings.append(msg)


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def strip_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


# ---------------------------------------------------------------------------
# 1. Filelists resolve
# ---------------------------------------------------------------------------
def check_filelists() -> None:
    incdirs: list[Path] = []
    listed: list[Path] = []

    for f in sorted((ROOT / "sim").glob("*.f")):
        for raw in read(f).splitlines():
            line = raw.split("//")[0].strip()
            if not line:
                continue
            line = line.replace("${OPENPCIE_ROOT}", str(ROOT))
            if line.startswith("+incdir+"):
                d = Path(line[len("+incdir+"):])
                check(d.is_dir(), f"{f.name}: +incdir path missing: {d}")
                incdirs.append(d)
            elif line.startswith("+") or line.startswith("-"):
                continue
            else:
                p = Path(line)
                check(p.is_file(), f"{f.name}: source not found: {p}")
                if p.is_file():
                    listed.append(p)

    # 2. Every `include resolves on the include path
    for src in listed:
        body = read(src)
        for inc in re.findall(r'`include\s+"([^"]+)"', body):
            if inc.startswith("uvm_"):
                continue                       # provided by the UVM library
            found = (src.parent / inc).is_file() or \
                    any((d / inc).is_file() for d in incdirs)
            check(found, f"{src.name}: `include \"{inc}\" not on the include path")

    # Any .svh in tb/ that no package pulls in is dead weight - flag it.
    included = set()
    for src in listed:
        for inc in re.findall(r'`include\s+"([^"]+)"', read(src)):
            included.add(inc)
    # svh files reachable transitively through env/test packages
    for pkg in listed:
        if pkg.suffix == ".sv":
            for inc in re.findall(r'`include\s+"([^"]+)"', read(pkg)):
                for d in incdirs:
                    q = d / inc
                    if q.is_file():
                        for inc2 in re.findall(r'`include\s+"([^"]+)"', read(q)):
                            included.add(inc2)

    for svh in sorted((ROOT / "tb").rglob("*.svh")):
        check(svh.name in included,
              f"{svh.relative_to(ROOT)} is never `include'd by any package")


# ---------------------------------------------------------------------------
# 2b. No clocking-block outputs on the DUT-facing interfaces
# ---------------------------------------------------------------------------
def check_no_clocking_outputs() -> None:
    """A clocking-block `output` elaborates to a driver on that signal.

    openpcie_axis_if is instantiated on both sides of the DUT, so a
    direction-specific clocking block puts a testbench driver on signals the
    DUT already drives structurally.  VCS reports:

      Warning-[ICPSD_W] Illegal combination of structural and procedural
      drivers ... The second driver is at "openpcie_axis_if.sv": output
      tvalid = tvalid

    and states it will become an error.  Drivers therefore assign the signals
    directly; clocking blocks are sample-only.  Guard the regression.
    """
    for agent, name in (("axis_agent", "openpcie_axis_if.sv"),
                        ("cfg_agent", "openpcie_cfg_if.sv")):
        p = ROOT / "tb" / "agents" / agent / name
        if not p.is_file():
            findings.append(f"{name} not found")
            continue
        src = strip_comments(read(p))
        for cb in re.finditer(r"clocking\s+(\w+).*?endclocking", src, re.S):
            outs = re.findall(r"^\s*(output|inout)\b", cb.group(0), re.M)
            check(not outs,
                  f"{name}: clocking block '{cb.group(1)}' declares "
                  f"{outs} - a clocking-block output is a driver, and these "
                  f"interfaces sit on DUT-driven signals (VCS ICPSD_W). "
                  f"Drive the signals directly instead.")

    # The drivers must not reference a driving clocking block either.
    for p in sorted((ROOT / "tb").rglob("*.svh")) + sorted((ROOT / "tb").rglob("*.sv")):
        src = strip_comments(read(p))
        for bad in ("mst_cb", "slv_cb", "drv_cb"):
            check(bad not in src,
                  f"{p.name} references removed clocking block '{bad}'")


# ---------------------------------------------------------------------------
# 3. tb_top DUT instantiation vs the RTL module declaration
# ---------------------------------------------------------------------------
def check_dut_ports() -> None:
    rtl = strip_comments(read(RTL_SOC))
    m = re.search(r"module\s+riscv_pcie_soc\s*\((.*?)\);", rtl, re.S)
    if not m:
        findings.append("could not locate riscv_pcie_soc port list")
        return
    rtl_ports = set(re.findall(
        r"\b(?:input|output|inout)\s+(?:logic|wire|reg)?\s*(?:\[[^\]]*\]\s*)?"
        r"([A-Za-z_]\w*)", m.group(1)))

    tb = strip_comments(read(ROOT / "tb" / "top" / "tb_top.sv"))
    m2 = re.search(r"riscv_pcie_soc\s+dut\s*\((.*?)\n\s*\);", tb, re.S)
    if not m2:
        findings.append("could not locate the DUT instantiation in tb_top.sv")
        return
    tb_ports = set(re.findall(r"\.\s*([A-Za-z_]\w*)\s*\(", m2.group(1)))

    for p in sorted(rtl_ports - tb_ports):
        findings.append(f"tb_top: DUT port '{p}' is not connected")
        globals().__setitem__("checks", checks + 1)
    for p in sorted(tb_ports - rtl_ports):
        findings.append(f"tb_top: connects '.{p}()' which riscv_pcie_soc "
                        f"does not declare")
        globals().__setitem__("checks", checks + 1)
    check(True, "dut port sets compared")


# ---------------------------------------------------------------------------
# 4. Mailbox constants agree across firmware / build script / types package
# ---------------------------------------------------------------------------
def check_mailbox_consts() -> None:
    types = read(ROOT / "tb" / "common" / "openpcie_types_pkg.sv")
    build = read(ROOT / "tb" / "fw" / "build_fw.py")
    asm = read(ROOT / "tb" / "fw" / "mailbox_fw.s")

    m = re.search(r"MBOX_BASE\s*=\s*0x([0-9A-Fa-f]+)", build)
    py_base = int(m.group(1), 16) if m else None
    m = re.search(r"MBOX_BASE\s*=\s*32'h([0-9A-Fa-f_]+)", types)
    sv_base = int(m.group(1).replace("_", ""), 16) if m else None
    check(py_base is not None and py_base == sv_base,
          f"mailbox base differs: build_fw.py=0x{py_base:X} vs "
          f"types_pkg=0x{sv_base:X}" if py_base and sv_base
          else "could not parse mailbox base from both sources")
    check(f"0x{py_base:08X}".lower()[2:].lstrip("0") in asm.lower().replace("_", "")
          or "0x00001F00".lower() in asm.lower(),
          "mailbox_fw.s does not appear to load the same mailbox base")

    m = re.search(r"ALIVE_MAGIC\s*=\s*0x([0-9A-Fa-f_]+)", build)
    py_magic = int(m.group(1).replace("_", ""), 16) if m else None
    m = re.search(r"MBOX_ALIVE_MAGIC\s*=\s*32'h([0-9A-Fa-f_]+)", types)
    sv_magic = int(m.group(1).replace("_", ""), 16) if m else None
    check(py_magic == sv_magic,
          f"ALIVE magic differs: 0x{py_magic:X} vs 0x{sv_magic:X}")

    # Field offsets
    py_fields = dict(re.findall(r'"(\w+)":\s*0x([0-9A-Fa-f]+)', build))
    for name, off in [("CMD", 0x00), ("ARG0", 0x04), ("ARG1", 0x08),
                      ("ARG2", 0x0C), ("ARG3", 0x10), ("RSP", 0x14),
                      ("ACK", 0x18), ("ALIVE", 0x1C)]:
        check(name in py_fields and int(py_fields[name], 16) == off,
              f"build_fw.py mailbox field {name} != 0x{off:02X}")
        m = re.search(rf"MBOX_{name}\s*=\s*MBOX_BASE\s*\+\s*32'h([0-9A-Fa-f]+)",
                      types)
        check(m is not None and int(m.group(1), 16) == off,
              f"types_pkg MBOX_{name} != MBOX_BASE + 0x{off:02X}")

    # Firmware command encodings
    for name, val in [("SEND_TLP", 1), ("READ_REG", 2), ("WRITE_REG", 3),
                      ("NOP", 4)]:
        m = re.search(rf"FW_CMD_{name}\s*=\s*32'd(\d+)", types)
        check(m is not None and int(m.group(1)) == val,
              f"types_pkg FW_CMD_{name} != {val}")


# ---------------------------------------------------------------------------
# 5. Bridge register offsets agree with the RTL decode
# ---------------------------------------------------------------------------
def check_reg_map() -> None:
    types = read(ROOT / "tb" / "common" / "openpcie_types_pkg.sv")
    ral = read(ROOT / "tb" / "ral" / "openpcie_ral.svh")

    expected = {"TX_HDR0": 0x00, "TX_HDR1": 0x04, "TX_HDR2": 0x08,
                "TX_DATA": 0x0C, "RX_STATUS": 0x10, "RX_DATA": 0x14,
                "RX_HDR_INFO": 0x18, "ERR_STATUS": 0x1C, "PHY_STATUS": 0x20}

    for name, off in expected.items():
        m = re.search(rf"REG_{name}\s*=\s*32'h([0-9A-Fa-f_]+)", types)
        check(m is not None and int(m.group(1).replace("_", ""), 16) == off,
              f"types_pkg REG_{name} != 0x{off:02X}")
        m = re.search(rf"add_reg\(\s*{name}\s*,\s*32'h([0-9A-Fa-f]+)", ral)
        check(m is not None and int(m.group(1), 16) == off,
              f"RAL map offset for {name} != 0x{off:02X}")

    # Every offset must sit inside the 64-byte alias period.
    for name, off in expected.items():
        check(off < 0x40,
              f"{name} at 0x{off:02X} is outside the bridge's 64-byte decode "
              f"window and would alias")

    # RAM depth must match the RTL array bound.
    rtl = read(RTL_SOC)
    m = re.search(r"ram\s*\[\s*0\s*:\s*(\d+)\s*\]", rtl)
    depth = int(m.group(1)) + 1 if m else None
    m = re.search(r"RAM_WORDS\s*=\s*(\d+)", types)
    sv_depth = int(m.group(1)) if m else None
    check(depth == sv_depth,
          f"RAM depth: RTL has {depth} words, types_pkg says {sv_depth}")

    # The mailbox backdoor's ref port must match the RTL array type exactly.
    bk = read(ROOT / "tb" / "top" / "openpcie_ram_bkdr_if.sv")
    m = re.search(r"interface\s+openpcie_ram_bkdr_if\s*\(\s*ref\s+logic\s*"
                  r"\[\s*31\s*:\s*0\s*\]\s*\w+\s*\[\s*0\s*:\s*(\d+)\s*\]", bk)
    bk_depth = int(m.group(1)) + 1 if m else None
    check(bk_depth == depth,
          f"openpcie_ram_bkdr_if ref port holds {bk_depth} words, RTL RAM "
          f"holds {depth}")
    bind = strip_comments(read(ROOT / "tb" / "top" / "openpcie_bind.sv"))
    check(re.search(r"bind\s+riscv_pcie_soc\s+openpcie_ram_bkdr_if\s+u_bkdr\s*"
                    r"\(\s*\.mem\s*\(\s*ram\s*\)\s*\)", bind) is not None,
          "tb/top/openpcie_bind.sv is missing "
          "'bind riscv_pcie_soc openpcie_ram_bkdr_if u_bkdr (.mem(ram))'")

    hexfile = ROOT / "build" / "fw" / "firmware.hex"
    if hexfile.is_file():
        n = len([l for l in read(hexfile).splitlines() if l.strip()])
        check(n == depth,
              f"firmware.hex has {n} lines but the RTL RAM holds {depth} words")

    # The mailbox must live inside the RAM.
    m = re.search(r"MBOX_BASE\s*=\s*32'h([0-9A-Fa-f_]+)", types)
    base = int(m.group(1).replace("_", ""), 16)
    check(base // 4 + 8 <= depth,
          f"mailbox at 0x{base:X} does not fit in a {depth}-word RAM")


# ---------------------------------------------------------------------------
# 6. Tests named in the Makefile exist in the test library
# ---------------------------------------------------------------------------
def check_tests() -> None:
    mk = read(ROOT / "sim" / "Makefile")
    lib = read(ROOT / "tb" / "tests" / "openpcie_test_lib.svh")
    declared = set(re.findall(r"class\s+(openpcie_\w*test)\s+extends", lib))

    m = re.search(r"^TESTS \?=(.*?)(?=^\w|\Z)", mk, re.S | re.M)
    listed = set(re.findall(r"(openpcie_\w*test)", m.group(1))) if m else set()

    for t in sorted(listed - declared):
        findings.append(f"Makefile TESTS names '{t}' which is not declared "
                        f"in openpcie_test_lib.svh")
    for t in sorted(declared - listed - {"openpcie_base_test"}):
        findings.append(f"test '{t}' exists but is not in the Makefile "
                        f"regression list")
    check(True, "test lists compared")

    # Sequences referenced by tests must exist.
    seqlib = read(ROOT / "tb" / "seq" / "openpcie_vseq_lib.svh") + \
             read(ROOT / "tb" / "seq" / "openpcie_base_vseq.svh")
    seqs = set(re.findall(r"class\s+(openpcie_\w*vseq)\s+extends", seqlib))
    for ref in set(re.findall(r'm_vseq_name\s*=\s*"(\w+)"', lib)):
        check(ref in seqs,
              f"test library references sequence '{ref}' which is not declared")


# ---------------------------------------------------------------------------
def main() -> int:
    check_filelists()
    check_no_clocking_outputs()
    check_dut_ports()
    check_mailbox_consts()
    check_reg_map()
    check_tests()

    print(f"openPCIE UVM static checks: {checks} performed")
    if findings:
        print(f"\n{len(findings)} finding(s):\n")
        for f in findings:
            print(f"  FAIL  {f}")
        return 1
    print("all clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
