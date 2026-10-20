#!/usr/bin/env python3
"""
Vivado xsim runner for the Tier 1 UVM environment - the xsim counterpart of
the VCS/Xcelium targets in sim/Makefile, for machines with Vivado and no make.

    python scripts/run.py                         # compile + smoke test
    python scripts/run.py -t openpcie_random_test -s 7
    python scripts/run.py --regress [--seeds 3]   # full suite
    python scripts/run.py --no-compile -t ...     # reuse the last snapshot
    python scripts/run.py --regress --seeds 5 --cov-report
    python scripts/run.py --cov-report --report-only --logdir regress_fixed
    python scripts/run.py --fixes --regress       # with the RTL fixes applied

Compiles the sources listed in sim/rtl.f and sim/tb.f - the same ones the
Makefile hands to VCS and Xcelium - once into build/xsim/, then runs each test
there with its own log under build/xsim/<logdir>/.  Set VIVADO_BIN if xvlog is
not on PATH.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIM = ROOT / "sim"
WORK = ROOT / "build" / "xsim"
LOGS = WORK / "logs"
SNAPSHOT = "tb_top_snap"

TESTS = [
    "openpcie_smoke_test",
    "openpcie_tx_directed_test",
    "openpcie_tx_random_test",
    "openpcie_tx_backpressure_test",
    "openpcie_tx_slow_sink_test",
    "openpcie_tx_burst_sink_test",
    "openpcie_rx_cpl_test",
    "openpcie_reg_access_test",
    "openpcie_sideband_test",
    "openpcie_reset_test",
    "openpcie_random_test",
]


def tool(name: str) -> str:
    exe = name + (".bat" if os.name == "nt" else "")
    vb = os.environ.get("VIVADO_BIN")
    if vb:
        return str(Path(vb) / exe)
    found = shutil.which(exe)
    if found:
        return found
    for cand in sorted(Path("D:/AMDDesignTools").glob("*/Vivado/bin")) + \
                sorted(Path("C:/Xilinx/Vivado").glob("*/bin")):
        if (cand / exe).exists():
            return str(cand / exe)
    sys.exit(f"cannot find {exe}; set VIVADO_BIN")


def parse_filelist(path: Path) -> tuple[list[str], list[str]]:
    incdirs, files = [], []
    for raw in path.read_text().splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line:
            continue
        line = line.replace("${OPENPCIE_ROOT}", ROOT.as_posix())
        if line.startswith("+incdir+"):
            incdirs.append(line[len("+incdir+"):])
        else:
            files.append(line)
    return incdirs, files


def run(cmd: list[str], log: Path | None = None) -> int:
    print("  $", " ".join(Path(cmd[0]).name if i == 0 else c
                          for i, c in enumerate(cmd))[:200])
    res = subprocess.run(cmd, cwd=WORK, text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        log.write_text(res.stdout)
    return res.returncode, res.stdout


def compile_all(fixes: bool, defines: list[str]) -> None:
    py = sys.executable
    print("=== prep: firmware, patch layer ===")
    for args in (["tb/fw/build_fw.py"],
                 ["scripts/rtl_patches.py"] + (["--with-fixes"] if fixes else [])):
        r = subprocess.run([py] + args, cwd=ROOT, text=True,
                           capture_output=True)
        if r.returncode:
            sys.exit(r.stdout + r.stderr)

    WORK.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    # The DUT does $readmemh("firmware.hex") from the run directory.
    shutil.copy(ROOT / "build" / "fw" / "firmware.hex", WORK / "firmware.hex")

    inc, rtl = parse_filelist(SIM / "rtl.f")
    inc2, dv = parse_filelist(SIM / "tb.f")
    incargs = [a for d in inc + inc2 for a in ("-i", d)]
    # OPENPCIE_RTL_FIXES tells the predictor the RTL carries the optional
    # fixes (it models the fixed write decode, rtl_patches.py RTL-FIX-002).
    defargs = [a for d in ["XSIM"] + (["OPENPCIE_RTL_FIXES"] if fixes else [])
               + defines for a in ("-d", d)]

    print("=== xvlog ===")
    rc, out = run([tool("xvlog"), "--sv", "-L", "uvm", *defargs, *incargs,
                   *rtl, *dv, "--log", str(WORK / "xvlog.log")])
    if rc:
        print(tail_errors(out)); sys.exit("xvlog failed - see build/xsim/xvlog.log")

    print("=== xelab ===")
    # --debug typical is required, not cosmetic: without it xsim's optimiser
    # breaks the ref-port aliasing in openpcie_ram_bkdr_if, the mailbox reads a
    # stale copy of the RAM, and every test dies waiting for firmware boot.
    rc, out = run([tool("xelab"), "tb_top", "-L", "uvm", "-relax",
                   "--debug", "typical",
                   "-timescale", "1ns/1ps", "-s", SNAPSHOT,
                   "--log", str(WORK / "xelab.log")])
    if rc:
        print(tail_errors(out)); sys.exit("xelab failed - see build/xsim/xelab.log")


def tail_errors(out: str) -> str:
    errs = [l for l in out.splitlines() if re.search(r"ERROR|Error", l)]
    return "\n".join(errs[:30]) or out[-3000:]


def run_test(test: str, seed: int, verb: str) -> bool:
    log = LOGS / f"{test}_{seed}.log"
    # Options go through a file: xsim.bat is a cmd script, and cmd splits
    # arguments on '=', which mangles UVM_TESTNAME=<test>.
    opts = LOGS / f"{test}_{seed}.opts"
    opts.write_text("\n".join([
        "-R", "-sv_seed", str(seed),
        "-testplusarg", f"UVM_TESTNAME={test}",
        "-testplusarg", f"UVM_VERBOSITY={verb}",
        # One functional-coverage database per run, next to its log, so
        # --cov-report can merge them (xsim would otherwise overwrite one).
        "-cov_db_dir", LOGS.as_posix(), "-cov_db_name", f"{test}_{seed}",
        "-log", log.as_posix()]) + "\n")
    rc, out = run([tool("xsim"), SNAPSHOT, "-f", str(opts)])
    if not log.exists():
        log.write_text(out)
    text = log.read_text(errors="replace") if log.exists() else out
    ok = "TEST PASSED" in text
    print(f"{'PASS' if ok else 'FAIL'}  {test:34s} seed {seed}   ({log.relative_to(ROOT)})")
    if not ok:
        for l in [l for l in text.splitlines()
                  if re.search(r"UVM_(ERROR|FATAL) |Error:|FATAL_ERROR", l)][:8]:
            print("      " + l.strip()[:220])
    return ok


def cov_report() -> None:
    """Merge every run's covergroup database in LOGS and write text + html."""
    out = LOGS / "cov_report"
    print(f"=== xcrg: merging {LOGS.relative_to(ROOT)} ===")
    # xcrg's directory scan finds nothing on Windows, and absolute paths also
    # fail; a path relative to WORK plus explicit database names works.
    names = [a for d in sorted((LOGS / "xsim.covdb").glob("*/"))
             if d.name != "xcrg_mergedDB"
             for a in ("-cov_db_name", d.name)]
    if not names:
        sys.exit(f"no coverage databases under {LOGS}")
    # One call per format: '-report_format all' stops after the text report.
    for fmt in ("text", "html"):
        rc, txt = run([tool("xcrg"), "-cov_db_dir",
                       LOGS.relative_to(WORK).as_posix(), *names,
                       "-report_format", fmt,
                       "-report_dir", out.relative_to(WORK).as_posix(),
                       "-log", (LOGS / f"xcrg_{fmt}.log").relative_to(WORK).as_posix()])
        # xcrg 2026.1 on Windows segfaults part-way through the text report
        # (it stops after the first covergroup) but writes the HTML report in
        # full. Judge by the files, not the return code, and read the HTML.
        rep = out / "functionalCoverageReport"
        made = (rep / "xcrg_func_cov_report.txt").exists() if fmt == "text" \
            else any(rep.glob("*.html"))
        if not made:
            print(tail_errors(txt)); sys.exit(f"xcrg ({fmt}) failed, rc={rc}")
    print(f"coverage report: {out.relative_to(ROOT)}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-t", "--test", default="openpcie_smoke_test")
    ap.add_argument("-s", "--seed", type=int, default=1)
    ap.add_argument("--regress", action="store_true")
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--verb", default="UVM_MEDIUM")
    ap.add_argument("--fixes", action="store_true",
                    help="apply optional functional RTL fixes (TX-PROTO-004)")
    ap.add_argument("--no-compile", action="store_true")
    ap.add_argument("-D", "--define", action="append", default=[])
    ap.add_argument("--cov-report", action="store_true",
                    help="merge the logdir's coverage databases and report")
    ap.add_argument("--report-only", action="store_true",
                    help="with --cov-report: skip compile and tests")
    ap.add_argument("--logdir", default="logs",
                    help="log directory under build/xsim/ (default: logs)")
    a = ap.parse_args()

    global LOGS
    LOGS = WORK / a.logdir
    LOGS.mkdir(parents=True, exist_ok=True)

    if a.report_only:
        cov_report()
        return

    if not a.no_compile:
        compile_all(a.fixes, a.define)

    jobs = ([(t, s) for t in TESTS for s in range(1, a.seeds + 1)]
            if a.regress else [(a.test, a.seed)])
    print("=== xsim ===")
    results = [(t, s, run_test(t, s, a.verb)) for t, s in jobs]
    npass = sum(ok for *_, ok in results)
    print(f"\n{npass} passed, {len(results) - npass} failed")
    if a.cov_report:
        cov_report()
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
