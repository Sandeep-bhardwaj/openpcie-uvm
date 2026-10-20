# Results

Tier 1 regression results for `riscv_pcie_soc` at openPCIE commit `6e48e11`.

| | |
|---|---|
| Date | 2026-10-20 |
| Simulator | AMD Vivado 2026.1 xsim, bundled UVM 1.2 |
| Tests | 11, seeds 1-5 each (55 runs per configuration) |
| Commands | `python scripts/run.py --regress --seeds 5 --logdir regress_nofix`<br>`python scripts/run.py --fixes --regress --seeds 5 --logdir regress_fixed --cov-report` |

Two configurations are run:

- **RTL as written**: the upstream RTL plus only the patch needed to elaborate
  (RTL-SIM-001, `always_ff` to `always` on the RAM).
- **With fixes**: additionally the two functional fixes, TX-PROTO-004 and
  REG-004 (`--fixes`). The predictor is switched to the fixed write decode by
  the same option.

## Summary

| Configuration | Passed | Failed | Warnings |
|---|---|---|---|
| RTL as written | 35 / 55 | 20 (the 4 stalling-sink tests, every seed) | 0 |
| With fixes | **55 / 55** | 0 | 0 |

## Per test

Checks are counted on the fixed-RTL run and summed over the five seeds. "TX
packets" are packets compared by the scoreboard; "readbacks" are register reads
compared with the predictor. There were no mismatches in any run.

| Test | RTL as written | With fixes | Simulated time per seed | TX packets | Readbacks |
|---|---|---|---|---|---|
| `openpcie_smoke_test` | 5/5 | 5/5 | 10.6 us | 5 | 10 |
| `openpcie_tx_directed_test` | 5/5 | 5/5 | 69.6 us | 190 | 0 |
| `openpcie_tx_random_test` | 5/5 | 5/5 | 174-590 us | 885 | 0 |
| `openpcie_tx_backpressure_test` | **0/5** | 5/5 | 123-244 us | 575 | 0 |
| `openpcie_tx_slow_sink_test` | **0/5** | 5/5 | 123-244 us | 575 | 0 |
| `openpcie_tx_burst_sink_test` | **0/5** | 5/5 | 123-244 us | 575 | 0 |
| `openpcie_rx_cpl_test` | 5/5 | 5/5 | 134-353 us | 0 | 654 |
| `openpcie_reg_access_test` | 5/5 | 5/5 | 39.9 us | 5 | 80 |
| `openpcie_sideband_test` | 5/5 | 5/5 | 294 us | 45 | 75 |
| `openpcie_reset_test` | 5/5 | 5/5 | 37.8 us | 80 | 10 |
| `openpcie_random_test` | **0/5** | 5/5 | 133-538 us | 689 | 118 |
| **Total** | **35/55** | **55/55** | | **3624** | **947** |

The randomised tests draw their packet count from the seed, which is why their
simulated time varies. `tx_backpressure`, `tx_slow_sink` and `tx_burst_sink`
run the same sequence with different sink profiles, so with the same seed they
send the same packets.

## Failures on the RTL as written

All 20 failing runs are the four tests whose sink stalls. Every error in them
comes from TX-PROTO-004 (the TX state machine checks `tready` one cycle
early); there is no other error ID.

| Error ID | Count | Meaning |
|---|---|---|
| `AXIS/PROTO` | 3447 | Monitor: payload changed during a stall, `tvalid` dropped before acceptance |
| `SVA/AXIS` | 400 | AXIS-001 / AXIS-002 on `s_axis_tx` (first 20 per run reported) |
| `SVA/SOC` | 196 | SOC-002: first beat not followed by a terminating beat (first 20 per run reported) |
| `SCBD/TX` | 120 | Packet mismatch: wrong beat count or header lost |
| **Total** | **4163** | |

By test:

| Test | `AXIS/PROTO` | `SVA/AXIS` | `SVA/SOC` | `SCBD/TX` |
|---|---|---|---|---|
| `openpcie_tx_backpressure_test` | 700 | 100 | 100 | 60 |
| `openpcie_tx_slow_sink_test` | 1150 | 100 | 0 | 0 |
| `openpcie_tx_burst_sink_test` | 1150 | 100 | 0 | 0 |
| `openpcie_random_test` | 447 | 100 | 96 | 60 |

With the slow and bursty sinks, the beats the sink finally accepts happen to be
the right ones (all 70 packets of seed 1 match the prediction), but the DUT
changes `tdata` and drops `tvalid` while a beat is waiting. Only the protocol
checks see that, which is why those two tests have no `SCBD/TX` or SOC-002
errors. With the random sinks beats are really lost or duplicated: the
scoreboard sees 1- and 3-beat packets (64 of 70 packets mismatch in
`openpcie_tx_backpressure_test` seed 1) and SOC-002 fires.

A typical first error (`openpcie_tx_backpressure_test`, seed 1):

```
UVM_ERROR @ 3544000: reporter [SVA/AXIS] [s_axis_tx] AXIS-001: tvalid deasserted before tready was seen
UVM_ERROR @ 3544000: reporter [SVA/SOC] SOC-002: first beat was not followed by a terminating beat
UVM_ERROR @ 5224000: reporter [SVA/AXIS] [s_axis_tx] AXIS-002: payload changed during a stall -
                     tdata/tkeep/tlast must hold until tready. (was 40000004/f/1)
UVM_ERROR @ 5240000: uvm_test_top.env.scoreboard [SCBD/TX] TX packet mismatch (#1 observed)
                     beat count: expected 2, observed 3
```

`openpcie_reg_access_test` passes in both configurations, but it observes
REG-004 on the RTL as written: the write of an MRd header to `PHY_STATUS`
(`+0x20`) lands in `TX_HDR0`, and the packet that follows goes out as that MRd
(final `tkeep` `0x0F`) instead of the MWr written through the register model.
The predictor models the RTL decode, so the compare matches. With the fixes
the write is ignored and the MWr goes out; the predictor follows that too.

## Functional coverage

Merged over the 55 runs with fixes (`xcrg`, HTML report in
`build/xsim/regress_fixed/cov_report/`).

| Covergroup | Weight | Coverage |
|---|---|---|
| `cg_reg_access` | 1 | 100 % |
| `cg_tlp` | 1 | 100 % |
| `cg_sideband` | 1 | 100 % |
| `cg_packet_t1` (TX and RX agents) | 1 | 100 % |
| `cg_packet` (all shapes, kept for Tier 2) | 0 | 24.1 % |
| `cg_tlp_diag` (non-conforming Fmt/`tkeep`, must stay empty) | 0 | 0 % |
| **Score** | | **100 %** |

Before coverage closure (2026-09-26) the score was 55.6 %. The stimulus and
model changes that closed it are listed in
[verification_plan.md, section 8](verification_plan.md#8-coverage-plan).

## Not yet measured

- Assertion cover points (`cover property`): xsim ignores them. Needs VCS or
  Xcelium (`make regress COV=1`).
- Code coverage (line, branch, FSM, toggle).
- Runs beyond 5 seeds per test.

## Static checks (same date)

| Check | Result |
|---|---|
| `tb/fw/build_fw.py` firmware self-test | 24 checks passed, 1798 instructions |
| `scripts/check_tb.py` | 233 checks, clean |
| `scripts/slang_check.py` (rtl and tb tiers) | 0 errors |
| `scripts/tx_fsm_model.py` | fixed model: no corruption under backpressure; original corrupts only when the sink stalls |
| Verible syntax and lint | clean |
| `patches/*.patch` | apply cleanly to openPCIE `6e48e11` |
