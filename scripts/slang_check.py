#!/usr/bin/env python3
"""
Compile the openPCIE UVM testbench with the slang front end (pyslang).

slang is a full IEEE 1800-2017 front end, so this is a real parse + elaborate,
not a text lint.  It is the closest thing to a VCS/Xcelium compile available
without either tool installed, and it catches the overwhelming majority of
first-compile failures.

    python scripts/slang_check.py              # all tiers
    python scripts/slang_check.py rtl          # DUT only
    python scripts/slang_check.py tb           # structured testbench
    python scripts/slang_check.py --warnings   # show warnings too

Tiers:
  rtl   riscv_pcie_soc + picorv32, fully elaborated with an explicit top.
        No UVM needed.
  tb    The whole testbench against a real UVM library, top = tb_top.

The UVM library (a source tree containing uvm_pkg.sv) is taken from $UVM_HOME,
else from build/uvm.  Without it the `tb` tier is skipped, not reported as
passing.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import pyslang
except ImportError:
    print("pyslang is not installed:  python -m pip install pyslang",
          file=sys.stderr)
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent

UVM_LIB_CANDIDATES = [
    os.environ.get("UVM_HOME", ""),
    str(ROOT / "build" / "uvm"),
]


def find_uvm() -> Path | None:
    for c in UVM_LIB_CANDIDATES:
        if not c:
            continue
        p = Path(c)
        if (p / "uvm_pkg.sv").is_file():
            return p
    return None


def run_slang(args: list[str]) -> list[str]:
    """Run the slang driver and return its diagnostic lines."""
    d = pyslang.driver.Driver()
    d.addStandardArgs()
    # The command line is re-parsed from a string, so paths must be POSIX -
    # backslashes are consumed as escapes.
    if not d.parseCommandLine(" ".join(args)):
        return ["error: slang parseCommandLine failed"]
    if not d.processOptions():
        return ["error: slang processOptions failed"]
    d.parseAllSources()

    comp = d.createCompilation()
    engine = pyslang.DiagnosticEngine(d.sourceManager)
    client = pyslang.TextDiagnosticClient()
    engine.addClient(client)
    for diag in comp.getAllDiagnostics():
        engine.issue(diag)
    return client.getString().splitlines()


def split_diags(lines: list[str]) -> tuple[list[str], list[str]]:
    """Group raw diagnostic lines into error blocks and warning blocks."""
    errors, warnings, cur, kind = [], [], [], None
    for ln in lines:
        m = re.search(r"\b(error|warning):", ln)
        if m:
            if cur and kind:
                (errors if kind == "error" else warnings).append("\n".join(cur))
            cur, kind = [ln], m.group(1)
        elif cur:
            cur.append(ln)
    if cur and kind:
        (errors if kind == "error" else warnings).append("\n".join(cur))
    return errors, warnings


def filelist_sources(name: str) -> tuple[list[str], list[str]]:
    """Return (incdirs, files) from a .f, with ${OPENPCIE_ROOT} expanded."""
    incdirs, files = [], []
    f = ROOT / "sim" / name
    for raw in f.read_text(encoding="utf-8").splitlines():
        line = raw.split("//")[0].strip()
        if not line:
            continue
        line = line.replace("${OPENPCIE_ROOT}", ROOT.as_posix())
        if line.startswith("+incdir+"):
            incdirs.append(Path(line[8:]).as_posix())
        elif not line.startswith(("+", "-")):
            files.append(Path(line).as_posix())
    return incdirs, files


# ---------------------------------------------------------------------------
# Tiers
# ---------------------------------------------------------------------------

def tier_rtl(show_warnings: bool) -> int:
    print("=" * 70)
    print("TIER 'rtl'  --  riscv_pcie_soc + picorv32, full elaboration")
    print("=" * 70)

    _, files = filelist_sources("rtl.f")
    args = ["slang"] + files + ["--top", "riscv_pcie_soc", "--single-unit"]
    errors, warnings = split_diags(run_slang(args))

    # PicoRV32 exposes PCPI, IRQ and look-ahead ports the SoC does not use.
    # That is a property of the design, not a defect, so it is filtered out
    # rather than left to drown the signal.
    warnings = [w for w in warnings
                if "unconnected-input-port" not in w
                and "unconnected-output-port" not in w]

    return report("rtl", errors, warnings, show_warnings)


def tier_tb(uvm_lib: Path, show_warnings: bool) -> int:
    print("=" * 70)
    print(f"TIER 'tb'   --  full testbench vs UVM at {uvm_lib}")
    print("=" * 70)

    _, rtl = filelist_sources("rtl.f")
    incdirs, dv = filelist_sources("tb.f")

    args = ["slang",
            f"+incdir+{uvm_lib.as_posix()}",
            (uvm_lib / "uvm_pkg.sv").as_posix()]
    args += [f"+incdir+{d}" for d in incdirs]
    args += rtl + dv
    args += ["--single-unit", "--top", "tb_top",
             # UVM's own headers are not our concern here.
             "--ignore-unknown-modules"]

    errors, warnings = split_diags(run_slang(args))
    errors, warnings = drop_uvm_noise(errors, warnings, uvm_lib)
    return report("tb", errors, warnings, show_warnings)


def drop_uvm_noise(errors, warnings, uvm_lib: Path):
    """Filter diagnostics originating inside the UVM library itself."""
    tag = uvm_lib.name
    def ours(block: str) -> bool:
        first = block.splitlines()[0]
        return f"{tag}\\" not in first and f"{tag}/" not in first
    return [e for e in errors if ours(e)], [w for w in warnings if ours(w)]


def report(tier: str, errors, warnings, show_warnings: bool) -> int:
    for e in errors:
        print(e)
        print()
    if show_warnings:
        for w in warnings:
            print(w)
            print()

    print(f"[{tier}] {len(errors)} error(s), {len(warnings)} warning(s)"
          + ("" if show_warnings or not warnings else "  (use --warnings to see them)"))
    print()
    return 1 if errors else 0


# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tiers", nargs="*", choices=["rtl", "tb"],
                    help="which tiers to run (default: all)")
    ap.add_argument("--warnings", action="store_true", help="show warnings")
    args = ap.parse_args()

    tiers = args.tiers or ["rtl", "tb"]
    uvm_lib = find_uvm()

    print(f"slang {pyslang.VersionInfo.getMajor()}."
          f"{pyslang.VersionInfo.getMinor()} via pyslang {pyslang.__version__}")
    print(f"UVM library: {uvm_lib if uvm_lib else 'NOT FOUND'}")
    print()

    rc = 0
    if "rtl" in tiers:
        rc |= tier_rtl(args.warnings)

    if uvm_lib is None:
        if "tb" in tiers:
            print("SKIPPED tier 'tb': no UVM library found.")
            print("Set UVM_HOME to a UVM source tree containing uvm_pkg.sv.")
            print("This tier is skipped, NOT passed.")
            rc |= 2
    else:
        if "tb" in tiers:
            rc |= tier_tb(uvm_lib, args.warnings)

    print("=" * 70)
    print("RESULT:", "PASS - no errors" if rc == 0 else
          ("SKIPPED (see above)" if rc == 2 else "FAIL - errors above"))
    print("=" * 70)
    return rc


if __name__ == "__main__":
    sys.exit(main())
