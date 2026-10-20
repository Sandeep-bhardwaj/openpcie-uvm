#!/usr/bin/env python3
"""
Cycle-accurate model of the riscv_pcie_soc transmit FSM, as written and as
fixed, driven by a stalling sink.

Purpose: prove that the proposed one-block RTL fix for TX-PROTO-004 actually
works, and that the original really does drop and duplicate beats -- without
needing a simulator.

    python scripts/tx_fsm_model.py            # compare both, 2000 packets
    python scripts/tx_fsm_model.py --trace    # cycle trace of the first failure

Model fidelity: outputs are registered exactly as in the RTL (assignments are
non-blocking, so what a sink sees this cycle is what was scheduled last cycle),
the bridge-write trigger is applied before the case statement, and `tready` is
sampled combinationally. That is the whole mechanism of the defect.
"""

from __future__ import annotations

import argparse
import random
import sys

IDLE, C1, C2 = 0, 1, 2
ST = {IDLE: "IDLE", C1: "C1", C2: "C2"}


class TxFsm:
    """riscv_pcie_soc.sv:191-213.  `fixed=True` applies the proposed change."""

    def __init__(self, fixed: bool):
        self.fixed = fixed
        self.state = IDLE
        # registered outputs - these are what the sink sees *now*
        self.tvalid = 0
        self.tdata = 0
        self.tkeep = 0
        self.tlast = 0
        # tx_header0/1/2 and tx_data are registers in the RTL, written by the
        # bridge accesses and then held for the whole packet.  The FSM reads
        # them in C1/C2, so they must be latched at the trigger - not sampled
        # live, or the model reads the *next* packet's header.
        self.h0 = self.h1 = self.h2 = self.pl = 0

    def step(self, tready: int, start: bool, hdr: tuple[int, int, int],
             payload: int):
        """Advance one clock. Returns the outputs that were visible this cycle."""
        seen = (self.tvalid, self.tdata, self.tkeep, self.tlast)

        ns = self.state
        nv, nd, nk, nl = self.tvalid, self.tdata, self.tkeep, self.tlast

        # The bridge write happens before the case statement in the RTL, and
        # latches the header/payload registers at the same time.
        if start:
            self.h0, self.h1, self.h2 = hdr
            self.pl = payload
            ns = C1

        h0, h1, h2 = self.h0, self.h1, self.h2
        beat0 = (h1 << 32) | h0
        beat1 = (self.pl << 32) | h2
        keep1 = 0xFF if (h0 >> 30) & 1 else 0x0F

        if self.state == IDLE:
            if self.fixed:
                # hold the final beat until it is actually accepted
                if (not self.tvalid) or tready:
                    nv = 0
            else:
                nv = 0

        elif self.state == C1:
            if self.fixed:
                # only load beat 0 when the bus is free, and advance with it
                if (not self.tvalid) or tready:
                    nd, nk, nl, nv = beat0, 0xFF, 0, 1
                    ns = C2
            else:
                # ORIGINAL: schedules beat 0 unconditionally, and advances on a
                # tready that refers to whatever was on the bus *before* it.
                nd, nk, nl, nv = beat0, 0xFF, 0, 1
                if tready:
                    ns = C2

        elif self.state == C2:
            if self.fixed:
                # beat 0 is on the bus now; move on only once it is taken
                if tready:
                    nd, nk, nl, nv = beat1, keep1, 1, 1
                    ns = IDLE
            else:
                nd, nk, nl, nv = beat1, keep1, 1, 1
                if tready:
                    ns = IDLE

        self.state = ns
        self.tvalid, self.tdata, self.tkeep, self.tlast = nv, nd, nk, nl
        return seen


def run(fixed: bool, n_packets: int, seed: int, stall_pct: int,
        trace: bool = False):
    rng = random.Random(seed)
    fsm = TxFsm(fixed)

    expected: list[list[tuple[int, int]]] = []
    pending: list[tuple[tuple[int, int, int], int]] = []
    for i in range(n_packets):
        has_data = rng.random() < 0.6
        h0 = (0x40000001 if has_data else 0x00000001) | (rng.getrandbits(8) << 16)
        h1 = rng.getrandbits(32)
        h2 = rng.getrandbits(32) & ~3
        pl = rng.getrandbits(32)
        pending.append(((h0, h1, h2), pl))
        expected.append([((h1 << 32) | h0, 0xFF),
                         ((pl << 32) | h2, 0xFF if has_data else 0x0F)])

    observed: list[list[tuple[int, int]]] = []
    cur: list[tuple[int, int]] = []

    # protocol violations
    v_tvalid_dropped = 0
    v_payload_moved = 0

    held = None
    idx = 0
    cycle = 0
    max_cycles = n_packets * 200
    first_bad = None

    while idx < len(pending) or fsm.state != IDLE or fsm.tvalid:
        if cycle > max_cycles:
            break
        cycle += 1

        tready = 1 if rng.randint(0, 99) >= stall_pct else 0
        start = False
        # issue the next packet only when the FSM is free, as the firmware does
        if fsm.state == IDLE and not fsm.tvalid and idx < len(pending):
            start = True

        hdr, pl = pending[idx] if idx < len(pending) else ((0, 0, 0), 0)
        tv, td, tk, tl = fsm.step(tready, start, hdr, pl)
        if start:
            idx += 1

        # ---- observe the bus exactly as the UVM monitor does --------------
        if tv:
            if held is not None:
                if (td, tk, tl) != held:
                    v_payload_moved += 1
                    if first_bad is None:
                        first_bad = (cycle, "payload changed during a stall",
                                     held, (td, tk, tl))
            if not tready:
                held = (td, tk, tl)
            else:
                held = None
                cur.append((td, tk))
                if tl:
                    observed.append(cur)
                    cur = []
        else:
            if held is not None:
                v_tvalid_dropped += 1
                if first_bad is None:
                    first_bad = (cycle, "tvalid dropped before tready", held, None)
            held = None

        if trace and cycle <= 60:
            print(f"    {cycle:4d}  state={ST[fsm.state]:4s} tready={tready} "
                  f"tvalid={tv} tlast={tl} tdata={td:016x}")

    matched = sum(1 for e, o in zip(expected, observed) if e == o)
    return {
        "packets_expected": len(expected),
        "packets_observed": len(observed),
        "matched": matched,
        "mismatched": len(observed) - matched,
        "tvalid_dropped": v_tvalid_dropped,
        "payload_moved": v_payload_moved,
        "cycles": cycle,
        "first_bad": first_bad,
    }


def check_rtl_matches_model() -> int:
    """Verify the patched RTL implements the FSM this model proved correct.

    This exists because of a real failure: the model was validated, then the
    RTL patch was written by hand and guarded only SEND_CYCLE_1 and
    SEND_CYCLE_2, leaving `IDLE: s_axis_tx_tvalid <= 1'b0;` unconditional.
    That drops the tlast beat whenever the sink stalls on it - a *new* bug,
    shipped because the patch was only checked for compilation, not for
    agreeing with the model.

    Each of the three arms must gate on the beat currently on the bus.
    """
    import re
    from pathlib import Path

    rtl = Path(__file__).resolve().parent.parent / "build" / "rtl_patched" \
        / "riscv_pcie_soc.sv"
    if not rtl.is_file():
        print("  (build/rtl_patched not generated - skipping RTL cross-check)")
        return 0

    src = rtl.read_text(encoding="utf-8")
    if "RTL-FIX-001" not in src:
        print("  (TX fix not applied - skipping RTL cross-check; "
              "use --with-fixes to enable it)")
        return 0

    # Search for the closing endcase *after* the tx_state case - the file has
    # earlier case statements (the register decode), and index("endcase") from
    # the start of the file lands on one of those, yielding an empty slice.
    start = src.index("case (tx_state)")
    body = src[start:src.index("endcase", start)]
    body = body.replace("\r\n", "\n")

    # Slice the case body at the arm labels rather than trying to match
    # `begin`/`end` pairs - indentation and line endings vary, and an
    # over-specific regex here silently fails to find anything, which is the
    # opposite of what a safety check should do.
    labels = [(m.start(), m.group(1)) for m in
              re.finditer(r"^\s*(IDLE|SEND_CYCLE_1|SEND_CYCLE_2|default)\s*:",
                          body, re.M)]
    arms = {}
    for i, (pos, name) in enumerate(labels):
        end = labels[i + 1][0] if i + 1 < len(labels) else len(body)
        if name != "default":
            arms[name] = body[pos:end]

    problems = []
    for arm, want in (("IDLE", r"!s_axis_tx_tvalid\s*\|\|\s*s_axis_tx_tready"),
                      ("SEND_CYCLE_1", r"!s_axis_tx_tvalid\s*\|\|\s*s_axis_tx_tready"),
                      ("SEND_CYCLE_2", r"if\s*\(\s*s_axis_tx_tready\s*\)")):
        if arm not in arms:
            problems.append(f"{arm}: arm not found in the patched RTL")
        elif not re.search(want, arms[arm]):
            problems.append(
                f"{arm}: missing its acceptance guard - the arm can change "
                f"tvalid/tdata while a beat is still unaccepted")

    print("  RTL cross-check (patched FSM vs the model proved above):")
    if problems:
        for p in problems:
            print(f"    FAIL  {p}")
        return 1
    print("    ok  all three arms gate on the beat currently on the bus")
    return 0


def report(title: str, r: dict) -> None:
    print(f"  {title}")
    print(f"    packets   : {r['packets_expected']} sent, "
          f"{r['packets_observed']} observed")
    print(f"    integrity : {r['matched']} matched, {r['mismatched']} corrupted")
    print(f"    AXIS-001  : {r['tvalid_dropped']} tvalid-dropped violation(s)")
    print(f"    AXIS-002  : {r['payload_moved']} payload-moved violation(s)")
    if r["first_bad"]:
        c, what, was, now = r["first_bad"]
        print(f"    first fail: cycle {c}, {what}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--packets", type=int, default=2000)
    ap.add_argument("--seeds", type=int, default=8)
    ap.add_argument("--stall", type=int, default=35, help="stall percentage")
    ap.add_argument("--trace", action="store_true")
    args = ap.parse_args()

    print("TX FSM model - riscv_pcie_soc.sv:191-213 vs the proposed fix")
    print(f"({args.packets} packets x {args.seeds} seed(s), "
          f"{args.stall}% stall)\n")

    print("=== no backpressure (stall = 0%) - the case that hides the bug ===")
    a = run(False, 200, 1, 0)
    b = run(True, 200, 1, 0)
    report("as written:", a)
    report("with fix  :", b)
    hidden = (a["mismatched"] == 0 and a["payload_moved"] == 0)
    print(f"\n  -> bug is {'HIDDEN' if hidden else 'visible'} "
          f"without backpressure (this is why the always-ready tests pass)\n")

    print(f"=== with backpressure (stall = {args.stall}%) ===")
    tot_a = {"mismatched": 0, "payload_moved": 0, "tvalid_dropped": 0}
    tot_b = dict(tot_a)
    for s in range(1, args.seeds + 1):
        ra = run(False, args.packets, s, args.stall)
        rb = run(True, args.packets, s, args.stall)
        for k in tot_a:
            tot_a[k] += ra[k]
            tot_b[k] += rb[k]
        if s == 1:
            report("as written:", ra)
            report("with fix  :", rb)

    print(f"\n  totals over {args.seeds} seed(s), "
          f"{args.packets * args.seeds} packets:")
    print(f"    as written : {tot_a['mismatched']} corrupted, "
          f"{tot_a['payload_moved']} AXIS-002, "
          f"{tot_a['tvalid_dropped']} AXIS-001")
    print(f"    with fix   : {tot_b['mismatched']} corrupted, "
          f"{tot_b['payload_moved']} AXIS-002, "
          f"{tot_b['tvalid_dropped']} AXIS-001")

    ok = (tot_b["mismatched"] == 0 and tot_b["payload_moved"] == 0
          and tot_b["tvalid_dropped"] == 0)
    broken = tot_a["mismatched"] > 0

    print()
    rtl_rc = check_rtl_matches_model()

    print()
    if rtl_rc != 0:
        print("RESULT: FAIL - the patched RTL does not implement the model.")
        return 1
    if ok and broken and hidden:
        print("RESULT: the fix is correct - zero corruption and zero protocol")
        print("        violations under backpressure, while the original")
        print("        corrupts packets only when the sink stalls.")
        return 0
    print("RESULT: UNEXPECTED - review the model.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
