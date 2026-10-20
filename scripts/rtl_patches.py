#!/usr/bin/env python3
"""
Minimal, documented patches applied to the design RTL so it will simulate.

The design RTL comes from the openPCIE submodule (rtl/openPCIE) and is never
edited.  Where it cannot be simulated as written, the fix is recorded here as
an explicit, reviewable text patch and applied into build/rtl_patched/, so it
is always obvious what was changed and why.

    python scripts/rtl_patches.py                         # generate
    python scripts/rtl_patches.py --check                 # verify up to date
    python scripts/rtl_patches.py --list                  # show the patches

Every patch here is a defect that should go upstream; each carries the vPlan
item that documents it.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL_SRC = ROOT / "rtl" / "openPCIE" / "2.rtl" / "2.RC-direct.opensource" / "src"
DEFAULT_OUT = ROOT / "build" / "rtl_patched"


class Patch:
    def __init__(self, file: str, old: str, new: str, vplan: str,
                 title: str, why: str, optional: bool = False):
        self.file, self.old, self.new = file, old, new
        self.vplan, self.title, self.why = vplan, title, why
        # Optional patches are OFF by default.  A mandatory patch is one
        # without which the design cannot simulate at all; an optional one
        # fixes a functional defect the verification plan is meant to report,
        # so applying it silently would hide the very finding being made.
        self.optional = optional


PATCHES = [
    Patch(
        file="riscv_pcie_soc.sv",
        old="    always_ff @(posedge clk) begin\n"
            "        ram_ready_reg <= 1'b0;",
        new="    // PATCHED (scripts/rtl_patches.py, RTL-SIM-001):\n"
            "    // always_ff -> always.  IEEE 1800-2017 9.2.2.4 forbids any other\n"
            "    // process writing a variable assigned in an always_ff block, and\n"
            "    // `ram` is also written by the $readmemh above.  VCS rejects the\n"
            "    // original with Error-[ICPD].  Semantics are unchanged.\n"
            "    always @(posedge clk) begin\n"
            "        ram_ready_reg <= 1'b0;",
        vplan="RTL-SIM-001",
        title="ram is written by both $readmemh and an always_ff block",
        why="riscv_pcie_soc.sv:99-120 declares `logic [31:0] ram [0:2047]`, "
            "initialises it from an `initial $readmemh(...)`, and also writes "
            "it from an `always_ff`. IEEE 1800-2017 9.2.2.4: variables written "
            "on the left-hand side of an always_ff shall not be written by any "
            "other process. VCS reports Error-[ICPD] and refuses to elaborate, "
            "so the design cannot simulate on VCS at all as written. Changing "
            "always_ff to always lifts the restriction with no change in "
            "simulation or synthesis behaviour. It also permits testbench "
            "backdoor loading of the RAM, which the same rule would otherwise "
            "forbid.",
    ),

    Patch(
        optional=True,
        file="riscv_pcie_soc.sv",
        old="""                IDLE: begin
                    s_axis_tx_tvalid <= 1'b0;
                end
                SEND_CYCLE_1: begin
                    s_axis_tx_tdata  <= {tx_header1, tx_header0};
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tlast  <= 1'b0;
                    if (s_axis_tx_tready) tx_state <= SEND_CYCLE_2;
                end
                SEND_CYCLE_2: begin
                    s_axis_tx_tdata  <= {tx_data, tx_header2};
                    s_axis_tx_tkeep  <= (tx_header0[30] == 1'b1) ? 8'hFF : 8'h0F;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tlast  <= 1'b1;

                    if (s_axis_tx_tready) begin
                        tx_state <= IDLE;
                    end
                end""",
        new="""                // PATCHED (rtl_patches.py RTL-FIX-001, vPlan TX-PROTO-004):
                // advance only when the beat actually on the bus is accepted.
                //
                // All three arms need the guard.  An earlier version of this
                // patch changed only SEND_CYCLE_1/2 and left IDLE clearing
                // tvalid unconditionally - which dropped the tlast beat
                // whenever the sink happened to stall on it.
                IDLE: begin
                    if (!s_axis_tx_tvalid || s_axis_tx_tready)
                        s_axis_tx_tvalid <= 1'b0;
                end
                SEND_CYCLE_1: begin
                    if (!s_axis_tx_tvalid || s_axis_tx_tready) begin
                        s_axis_tx_tdata  <= {tx_header1, tx_header0};
                        s_axis_tx_tkeep  <= 8'hFF;
                        s_axis_tx_tvalid <= 1'b1;
                        s_axis_tx_tlast  <= 1'b0;
                        tx_state         <= SEND_CYCLE_2;
                    end
                end
                SEND_CYCLE_2: begin
                    if (s_axis_tx_tready) begin
                        s_axis_tx_tdata  <= {tx_data, tx_header2};
                        s_axis_tx_tkeep  <= (tx_header0[30] == 1'b1) ? 8'hFF : 8'h0F;
                        s_axis_tx_tvalid <= 1'b1;
                        s_axis_tx_tlast  <= 1'b1;
                        tx_state         <= IDLE;
                    end
                end""",
        vplan="TX-PROTO-004",
        title="TX FSM samples tready one cycle before the beat is presented",
        why="riscv_pcie_soc.sv:195-211 drives s_axis_tx_* through registers, "
            "but evaluates s_axis_tx_tready in the same cycle it schedules "
            "them - so the state advances against a tready that refers to "
            "whatever was on the bus beforehand. With an always-ready sink the "
            "two off-by-one errors cancel; under backpressure beat 0 is "
            "overwritten by beat 1 before it was ever accepted, and tvalid can "
            "drop mid-beat. The fix advances only when the beat currently on "
            "the bus is taken, and holds the final beat in IDLE until accepted. "
            "Verified with scripts/tx_fsm_model.py: 16000 packets at 35% stall, "
            "zero corruption and zero protocol violations, against 15915 "
            "corrupted packets for the original. OFF BY DEFAULT - enable with "
            "--with-fixes (or make FIXES=1) to demonstrate the tests going "
            "green; leave it off to reproduce the finding.",
    ),

    Patch(
        optional=True,
        file="riscv_pcie_soc.sv",
        old="                if (mem_wstrb != '0) begin",
        new="                // PATCHED (rtl_patches.py RTL-FIX-002, vPlan REG-004):\n"
            "                // qualify the write decode with !mem_addr[5] so it matches\n"
            "                // the read decode.  Without it, writes to PHY_STATUS\n"
            "                // (+0x20) land on TX_HDR0 and +0x2C starts a transmit.\n"
            "                if (mem_wstrb != '0 && !mem_addr[5]) begin",
        vplan="REG-004",
        title="register writes ignore mem_addr[5] - PHY_STATUS writes hit TX_HDR0",
        why="riscv_pcie_soc.sv:175 decodes bridge writes on mem_addr[4:2] only, "
            "while the read decode also uses mem_addr[5] to select PHY_STATUS. "
            "So a write to the read-only PHY_STATUS (+0x20) overwrites "
            "TX_HDR0, and a write to +0x2C starts a transmit with whatever the "
            "header registers hold. Found while closing register-access "
            "coverage; confirmed by openpcie_reg_access_test, whose packet "
            "compare fails if the predictor does not model it. The fix adds "
            "!mem_addr[5] to the write enable. OFF BY DEFAULT; --with-fixes "
            "applies it, and every runner that passes --with-fixes also "
            "defines OPENPCIE_RTL_FIXES so the predictor switches its write "
            "decode to match.",
    ),
]


def apply(text: str, filename: str,
          with_fixes: bool = False) -> tuple[str, list[Patch]]:
    """Apply patches registered for `filename`; return (text, applied).

    Optional patches are skipped unless `with_fixes` is set.
    """
    applied = []
    for p in PATCHES:
        if p.file != filename:
            continue
        if p.optional and not with_fixes:
            continue
        if p.new in text:
            applied.append(p)          # already patched
            continue
        if p.old not in text:
            raise RuntimeError(
                f"patch {p.vplan} does not apply to {filename}: anchor text "
                f"not found. The RTL has changed - review the patch.")
        text = text.replace(p.old, p.new, 1)
        applied.append(p)
    return text, applied


def patched_files() -> set[str]:
    return {p.file for p in PATCHES}


def generate(out: Path, check_only: bool = False,
             with_fixes: bool = False) -> int:
    if not (RTL_SRC / "riscv_pcie_soc.sv").is_file():
        print(f"error: {RTL_SRC} not found - run "
              f"'git submodule update --init' first", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)
    stale, total = [], 0

    for src in sorted(RTL_SRC.glob("*.v")) + sorted(RTL_SRC.glob("*.sv")):
        with open(src, "r", encoding="utf-8", newline="") as fh:
            # Normalise line endings: a Windows checkout with core.autocrlf
            # gives CRLF, and the patch anchors are written with LF.
            text = fh.read().replace("\r\n", "\n")
        text, applied = apply(text, src.name, with_fixes)
        dst = out / src.name
        total += 1

        current = None
        if dst.is_file():
            with open(dst, "r", encoding="utf-8", newline="") as fh:
                current = fh.read()
        if current == text:
            continue
        if check_only:
            stale.append(src.name)
        else:
            with open(dst, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)

    active = [p for p in PATCHES if with_fixes or not p.optional]
    skipped = [p for p in PATCHES if p.optional and not with_fixes]

    if check_only:
        if stale:
            for s in stale:
                print(f"STALE  {s}")
            print("\nRun 'python scripts/rtl_patches.py' to regenerate.")
            return 1
        print(f"patched RTL up to date ({total} files, "
              f"{len(active)} patch(es) applied"
              + (f", {len(skipped)} optional fix(es) available)" if skipped
                 else ")"))
        return 0

    print(f"patched RTL written to {out}  "
          f"({total} files, {len(active)} patch(es) applied)")
    for p in active:
        tag = "FIX" if p.optional else "REQ"
        print(f"  [{tag}] {p.vplan}  {p.file}: {p.title}")
    for p in skipped:
        print(f"  [ - ] {p.vplan}  {p.file}: {p.title}")
        print(f"        not applied. Add --with-fixes (make FIXES=1) to "
              f"apply it and watch the failing tests go green.")
    return 0


def list_patches() -> int:
    print(f"{len(PATCHES)} RTL patch(es):\n")
    for p in PATCHES:
        kind = "OPTIONAL (off by default)" if p.optional else "REQUIRED"
        print(f"  {p.vplan}  {p.file}   [{kind}]")
        print(f"    {p.title}")
        for line in _wrap(p.why, 70):
            print(f"      {line}")
        print()
    return 0


def _wrap(s: str, w: int) -> list[str]:
    out, line = [], ""
    for word in s.split():
        if len(line) + len(word) + 1 > w:
            out.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    if line:
        out.append(line)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--with-fixes", action="store_true",
                    help="also apply the optional functional fixes, so the "
                         "failing tests can be watched going green")
    args = ap.parse_args()

    if args.list:
        return list_patches()
    return generate(args.out, args.check, args.with_fixes)


if __name__ == "__main__":
    sys.exit(main())
