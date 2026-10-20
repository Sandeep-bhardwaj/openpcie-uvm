#!/usr/bin/env python3
"""
Write the RTL fixes found by this testbench as unified diffs against
2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv of openPCIE (the commit
pinned by the rtl/openPCIE submodule). They apply with `git apply` from the
root of an openPCIE checkout.

    python scripts/make_upstream_patches.py          # write patches/
    python scripts/make_upstream_patches.py --check  # verify, write nothing

rtl_patches.py carries the same fixes for simulation, with commentary aimed at
this testbench.  The versions here keep only a short comment for the RTL
reader.  Each one is checked against its rtl_patches.py counterpart with
comments stripped, so what goes upstream is exactly the code that was
simulated.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT / "rtl" / "openPCIE"
REL = "2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv"
OUT = ROOT / "patches"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rtl_patches  # noqa: E402

# (file name, vPlan id, rtl_patches vplan key, summary, new text)
FIXES = [
    ("0001-ram-always-instead-of-always_ff.patch", "RTL-SIM-001",
     "RTL-SIM-001",
     "riscv_pcie_soc: write ram from always, not always_ff",
     "    // `ram` is also written by the $readmemh above, which IEEE 1800-2017\n"
     "    // 9.2.2.4 forbids for a variable assigned in always_ff.\n"
     "    always @(posedge clk) begin\n"
     "        ram_ready_reg <= 1'b0;"),
    ("0002-tx-fsm-honour-axis-handshake.patch", "TX-PROTO-004",
     "TX-PROTO-004",
     "riscv_pcie_soc: advance the TX FSM only on an accepted beat",
     None),   # taken from rtl_patches with its comment block trimmed
    ("0003-bridge-write-decode-use-addr5.patch", "REG-004", "REG-004",
     "riscv_pcie_soc: qualify bridge writes with !mem_addr[5]",
     "                // Match the read decode: +0x20..+0x3C is PHY_STATUS space.\n"
     "                if (mem_wstrb != '0 && !mem_addr[5]) begin"),
]

WHY = {
    "RTL-SIM-001":
        "ram is initialised by `$readmemh` in an initial block and written by\n"
        "an always_ff. IEEE 1800-2017 9.2.2.4 forbids any other process writing\n"
        "a variable assigned in always_ff; VCS rejects the file with\n"
        "Error-[ICPD]. `always` removes the restriction with no change in\n"
        "simulation or synthesis behaviour.",
    "TX-PROTO-004":
        "s_axis_tx_* are registered, but the FSM tested s_axis_tx_tready in the\n"
        "cycle it scheduled them, i.e. against whatever was on the bus before.\n"
        "With an always-ready sink the errors cancel; under backpressure beat 0\n"
        "(the TLP header) is overwritten by beat 1 before it is accepted, and\n"
        "tvalid can drop while a beat is pending (AXI4-Stream 2.2.1). The FSM\n"
        "now advances only when the beat on the bus is taken, and IDLE holds\n"
        "the final beat until accepted.",
    "REG-004":
        "The read decode uses mem_addr[5] to select PHY_STATUS at +0x20; the\n"
        "write decode used mem_addr[4:2] only. A write to the read-only\n"
        "PHY_STATUS therefore overwrote tx_header0, and a write to +0x2C\n"
        "started a transmit with whatever the header registers held.",
}


def strip_comments(text: str) -> str:
    lines = [re.sub(r"\s*//.*$", "", l).rstrip() for l in text.splitlines()]
    return "\n".join(l for l in lines if l.strip())


def patch_for(key: str) -> rtl_patches.Patch:
    return next(p for p in rtl_patches.PATCHES if p.vplan == key)


def upstream_new(key: str, new: str | None) -> str:
    p = patch_for(key)
    if new is None:
        # Trim rtl_patches' comment block to its first two lines.
        lines = p.new.splitlines()
        body = [l for l in lines if not l.strip().startswith("//")]
        indent = re.match(r"\s*", body[0]).group(0)
        new = "\n".join([
            f"{indent}// Advance only when the beat on the bus is accepted",
            f"{indent}// (AXI4-Stream: hold tvalid/tdata until tready).",
            *body])
    if strip_comments(new) != strip_comments(p.new):
        raise SystemExit(f"{key}: upstream text differs in code from the "
                         f"simulated rtl_patches.py version")
    return new


def unified(before: str, after: str) -> str:
    return "".join(difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile=f"a/{REL}", tofile=f"b/{REL}", n=3))


def header(summary: str, vplan: str) -> str:
    return (f"Subject: [PATCH] {summary}\n\n"
            f"{WHY[vplan]}\n\n"
            f"Found by the openpcie-uvm Tier 1 testbench ({vplan}); see\n"
            f"docs/verification_plan.md, section 11, in that repository.\n\n---\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    with open(REPO / REL, encoding="utf-8", newline="") as fh:
        orig = fh.read().replace("\r\n", "\n")

    outputs: dict[str, str] = {}
    combined = orig
    for name, vplan, key, summary, new in FIXES:
        p = patch_for(key)
        if orig.count(p.old) != 1:
            raise SystemExit(f"{key}: anchor not found exactly once in {REL}")
        new = upstream_new(key, new)
        outputs[name] = header(summary, vplan) + unified(orig, orig.replace(p.old, new))
        combined = combined.replace(p.old, new)

    outputs["all-fixes.patch"] = (
        "Subject: [PATCH] riscv_pcie_soc: fixes found by the openpcie-uvm testbench\n\n"
        + "\n\n".join(f"* {s} ({v})\n\n{WHY[v]}" for _, v, _, s, _ in FIXES)
        + "\n\n---\n" + unified(orig, combined))

    stale = []
    for name, text in outputs.items():
        dst = OUT / name
        cur = dst.read_text(encoding="utf-8") if dst.is_file() else None
        if cur != text:
            stale.append(name)
            if not a.check:
                OUT.mkdir(exist_ok=True)
                with open(dst, "w", encoding="utf-8", newline="") as fh:
                    fh.write(text)
    if a.check:
        print("upstream patches " + ("STALE: " + ", ".join(stale) if stale
                                     else f"up to date ({len(outputs)} files)"))
        return 1 if stale else 0
    print(f"wrote {len(outputs)} patch file(s) to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
