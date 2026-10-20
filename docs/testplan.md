# openPCIE Root Complex — Tier 1 Test Plan

| | |
|---|---|
| **Document** | TP-OPENPCIE-T1 |
| **Version** | 1.0 |
| **Date** | 2026-10-20 |
| **Status** | Released for review |
| **DUT** | `riscv_pcie_soc` |
| **Parent document** | [verification_plan.md](verification_plan.md). Requirement IDs (`TX-FMT-001`, …) are defined there in §6 |
| **Tracking workbook** | [testplan.xlsx](testplan.xlsx) |

### Revision history

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-10-20 | First issue: 11 test cases, traceability matrix, regression lists, results |

---

## Contents

1. [Scope](#1-scope)
2. [Test environment](#2-test-environment)
3. [Conventions and common pass criteria](#3-conventions-and-common-pass-criteria)
4. [Test case summary](#4-test-case-summary)
5. [Test case specifications](#5-test-case-specifications)
6. [Latest results](#6-latest-results)
7. [Requirements traceability matrix](#7-requirements-traceability-matrix)
8. [Regression lists](#8-regression-lists)

---

## 1. Scope

This plan specifies every test that verifies the Tier 1 requirements in
[verification_plan.md §6](verification_plan.md#6-feature-list-and-verification-requirements):
what each test sets up, what stimulus it applies, what it checks and what counts
as a pass. Out-of-scope items are listed in the verification plan, §3.2.

---

## 2. Test environment

### 2.1 Configuration knobs

Tests set policy in `configure()` before the environment is built; sequences
own the stimulus ([test library](../tb/tests/openpcie_test_lib.svh),
[sequence library](../tb/seq/openpcie_vseq_lib.svh)).

| Knob | Values | Meaning |
|---|---|---|
| `tx_cfg.ready_mode` | `READY_ALWAYS` | `tready` held high |
| | `READY_RANDOM` + `ready_pct` | `tready` high with the given probability each cycle |
| | `READY_SLOW` + `ready_period` | One beat accepted every N cycles |
| | `READY_BURST` + `burst_accept`/`burst_stall` | Alternating accept and stall runs |
| `require_tx_activity` | 0 / 1 | Scoreboard fails the test if no TX packet was checked |
| `build_ral` | 0 / 1 | Build the register model |
| `test_timeout` | time | Global watchdog |
| `OPENPCIE_RTL_FIXES` (define) | set by `--fixes` / `FIXES=1` | RTL carries the optional fixes, and the predictor models them |

### 2.2 Common stimulus primitives

| Primitive | Path | Effect |
|---|---|---|
| `send_tlp(t)` | Mailbox `SEND_TLP` | Firmware writes `TX_HDR0..2`, then `TX_DATA` (trigger) |
| `write_reg(off, v)` / `read_reg(off, v)` | Mailbox `WRITE_REG` / `READ_REG` | One CPU bus access to the bridge |
| `sync()` | Mailbox `NOP` | Barrier: every earlier command has retired |
| `inject_rx(t, gap)` | `rx_agent` | Drives a TLP on `m_axis_rx_*` |
| cfg sequences | `cfg_agent` | Static or random sideband values |

---

## 3. Conventions and common pass criteria

- **Test ID** `TC-nn`; the UVM test class is `openpcie_<name>_test`. Run one with
  `python scripts/run.py -t <class> -s <seed>` or
  `make TEST=<class> SEED=<seed>`.
- **Type**: D = directed, CR = constrained-random, D/CR = directed structure
  with random data.
- **Priority** follows the highest-priority requirement the test covers.

**Every test passes only if all of the following hold:**

1. The firmware boots (`ALIVE` magic seen) within 5000 cycles.
2. No `UVM_ERROR` or `UVM_FATAL`: scoreboard, monitor, mailbox and sequence checks are all clean.
3. No assertion failure (`AXIS-*`, `SOC-*`; reported as `SVA/AXIS` and `SVA/SOC` UVM errors).
4. The scoreboard has no leftover expected or observed items at end of test.
5. At least one TX packet is checked, unless the test clears `require_tx_activity`.
6. The test finishes before its timeout, and the report prints `TEST PASSED`.

---

## 4. Test case summary

| TC | Test class | Type | Pri | Sink profile | Requirements | Timeout |
|---|---|---|---|---|---|---|
| TC-01 | `openpcie_smoke_test` | D | P1 | always ready | SMOKE-001, TX-FMT-001 | 2 ms |
| TC-02 | `openpcie_tx_directed_test` | D | P1 | always ready | TX-FMT-001/002/003, TX-DATA-001 | 10 ms |
| TC-03 | `openpcie_tx_random_test` | CR | P1 | always ready | TX-RAND-001, TX-FMT-001/002/003 | 20 ms |
| TC-04 | `openpcie_tx_backpressure_test` | D/CR | P1 | random, 40 % ready | TX-PROTO-001/002/004 | 20 ms |
| TC-05 | `openpcie_tx_slow_sink_test` | D | P1 | 1 beat / 4 cycles | TX-PROTO-001/002/004 | 20 ms |
| TC-06 | `openpcie_tx_burst_sink_test` | D | P1 | 1 accept / 3 stall | TX-PROTO-001/002/004 | 20 ms |
| TC-07 | `openpcie_rx_cpl_test` | D/CR | P1 | always ready | RX-CAP-001/002/003 | 20 ms |
| TC-08 | `openpcie_reg_access_test` | D | P1 | always ready | REG-001..004, TX-TRIG-001/002 | 10 ms |
| TC-09 | `openpcie_sideband_test` | D | P1 | always ready | CFG-001/002/003, TX-FLOW-001 | 20 ms |
| TC-10 | `openpcie_reset_test` | D | P1 | always ready | RST-001/002 | 20 ms |
| TC-11 | `openpcie_random_test` | CR | P1 | random, 65 % ready | MIX-001, TX-PROTO-004, all groups | 60 ms |

Assertions `AXIS-*` and `SOC-*` run in every test, so TX-PROTO-001/003,
RX-CAP-004 and CPU-001 are checked continuously across the suite.

---

## 5. Test case specifications

### TC-01 — Smoke (`openpcie_smoke_test`)

| | |
|---|---|
| **Objective** | Prove the whole path is alive: reset, firmware boot, mailbox, one TLP out, status path answering. Gate for every other test. |
| **Requirements** | SMOKE-001, TX-FMT-001 |
| **Configuration** | `READY_ALWAYS`; timeout 2 ms |
| **Stimulus** | 1. Wait for firmware boot. 2. `send_tlp(MemWr32 @0x1000_0000, data 0xCAFE_BABE)`. 3. `sync()`. 4. Read `PHY_STATUS` and `ERR_STATUS`. |
| **Checks** | Scoreboard matches the 2-beat packet (final `tkeep=0xFF`); readbacks match the predictor; all SVA clean. |
| **Coverage** | `x_fmt_keep.ok_data_full`; `cp_offset.phy_status/err_status` read |
| **Pass** | Common criteria (§3) |

### TC-02 — Directed TX shapes (`openpcie_tx_directed_test`)

| | |
|---|---|
| **Objective** | Exercise both final-beat `tkeep` outcomes, boundary addresses and every payload bit. |
| **Requirements** | TX-FMT-001, TX-FMT-002, TX-FMT-003, TX-DATA-001 |
| **Configuration** | `READY_ALWAYS`; timeout 10 ms |
| **Stimulus** | 1. MemWr32 with all-zero, all-ones (`0xFFFF_FFFC`/`0xFFFF_FFFF`) and mixed (`0xDEAD_BEE0`/`0xA5A5_5A5A`) address/data. 2. MemRd32 at `0x1000_0000` and `0x8000_0004`. 3. One outbound CplD. 4. 32 MemWr32 with walking-ones payload `1 << i`. 5. `sync()`. |
| **Checks** | Every packet: beat 0 = `{HDR1,HDR0}`, beat 1 = `{DATA,HDR2}`; final `tkeep` 0xFF with payload, 0x0F without (scoreboard, SOC-003/004). |
| **Coverage** | `x_fmt_keep` both legal bins; `cp_type` mem, cpl |
| **Pass** | Common criteria; 38 packets matched |

### TC-03 — Random TX traffic (`openpcie_tx_random_test`)

| | |
|---|---|
| **Objective** | Randomised Tier 1 TLPs with an always-ready sink, as the control case for TC-04..06. |
| **Requirements** | TX-RAND-001, TX-FMT-001/002/003 |
| **Configuration** | `READY_ALWAYS`; timeout 20 ms |
| **Stimulus** | `n_tlps` ∈ [20, 400] (default 100). Each TLP: Fmt 3-DW with or without data (50/50); Type MEM (40 %), IO, CFG0, CFG1, CPL; MEM reads take Length 1 / 2–8 / 9–64 / 65–1023 / 1024 DW; all other kinds Length 1. Kind and Length are picked procedurally (xsim solver workaround, see the verification plan). |
| **Checks** | Scoreboard packet compare; SVA. |
| **Coverage** | `cg_tlp` — `cp_type`, `cp_fmt`, `cp_len`, `x_type_fmt`, `x_fmt_keep` |
| **Pass** | Common criteria |

### TC-04 — TX under random backpressure (`openpcie_tx_backpressure_test`)

| | |
|---|---|
| **Objective** | Verify that the TX FSM delivers every beat when the sink stalls at random. Targets TX-PROTO-004. |
| **Requirements** | TX-PROTO-001, TX-PROTO-002, TX-PROTO-004 |
| **Configuration** | `READY_RANDOM`, `ready_pct = 40`; timeout 20 ms |
| **Stimulus** | `n_tlps` ∈ [30, 200] (default 60), alternating MemWr32 and MemRd32, so both final-`tkeep` values are presented while stalling. |
| **Checks** | AXIS-001 (`tvalid` held), AXIS-002 (payload stable during a stall), monitor stability check, scoreboard packet compare; responder confirms that stalls occurred. |
| **Coverage** | `c_stall*`, `c_stall_on_first`, `c_tx_stall_in_c1/c2` |
| **Expected** | **RTL as written: FAIL** with `SVA/AXIS` (AXIS-001/002), `SVA/SOC` (SOC-002), `AXIS/PROTO` and `SCBD/TX` (TX-PROTO-004). **With fixes: PASS.** Any other error is a new failure. |

### TC-05 — TX with slow sink (`openpcie_tx_slow_sink_test`)

| | |
|---|---|
| **Objective** | Same as TC-04, with a deterministic stall pattern that is easier to debug. |
| **Requirements** | TX-PROTO-001, TX-PROTO-002, TX-PROTO-004 |
| **Configuration** | `READY_SLOW`, `ready_period = 4`; timeout 20 ms |
| **Stimulus** | As TC-04. |
| **Checks** | As TC-04. |
| **Expected** | As TC-04. |

### TC-06 — TX with bursty sink (`openpcie_tx_burst_sink_test`)

| | |
|---|---|
| **Objective** | Same as TC-04, with alternating accept and stall runs. |
| **Requirements** | TX-PROTO-001, TX-PROTO-002, TX-PROTO-004 |
| **Configuration** | `READY_BURST`, `burst_accept = 1`, `burst_stall = 3`; timeout 20 ms |
| **Stimulus** | As TC-04. |
| **Checks** | As TC-04. |
| **Expected** | As TC-04. |

### TC-07 — RX completion capture (`openpcie_rx_cpl_test`)

| | |
|---|---|
| **Objective** | Verify completion detection, capture of status, data and header, and that non-completion TLPs are ignored. |
| **Requirements** | RX-CAP-001, RX-CAP-002, RX-CAP-003 |
| **Configuration** | `READY_ALWAYS`; `require_tx_activity = 0` (no TX traffic); timeout 20 ms |
| **Stimulus** | 1. `n_cpl` ∈ [10, 100] (default 30) CplD, cycling the status through SC, UR, CRS and CA, with a unique tag and data, and a random 0–6 cycle gap; after each one, `sync()` and read `RX_STATUS`, `RX_DATA`, `RX_HDR_INFO`. 2. Four Cpl without data (UR, CRS, CA, SC); read `RX_STATUS` and `RX_HDR_INFO`. 3. One inbound MemWr32; read `RX_DATA`. |
| **Checks** | Every readback equals the predictor's RX capture shadow (`SCBD/RD`); after step 3, `RX_DATA` is unchanged. |
| **Coverage** | `cg_reg_access` rx_* reads; `cg_packet_t1` (rx) both `tkeep` bins |
| **Pass** | Common criteria (no TX activity required) |

### TC-08 — Register access (`openpcie_reg_access_test`)

| | |
|---|---|
| **Objective** | Verify the register map: readable decode, write-only holes, writes to read-only registers, header stickiness, the `TX_DATA` trigger and 64-byte aliasing. |
| **Requirements** | REG-001, REG-002, REG-003, REG-004, TX-TRIG-001, TX-TRIG-002 |
| **Configuration** | `build_ral = 1`; `READY_ALWAYS`; timeout 10 ms |
| **Stimulus** | 1. RAL-read all five readable registers. 2. RAL-write `TX_HDR0..2` (well-formed MWr header). 3. Read back `TX_HDR0..2` and `TX_DATA`. 4. Write `0xFFFF_FFFF` to `RX_STATUS`, `RX_DATA`, `RX_HDR_INFO` and `ERR_STATUS`; write an MRd header `0x0000_0001` to `PHY_STATUS` (+0x20). 5. RAL-read the five readable registers again. 6. RAL-write `TX_DATA` (arms the transmit). 7. Read `+0x14` and `+0x54`. |
| **Checks** | Step 3 reads return 0. Step 5 readbacks are unchanged. **Step 6 packet:** RTL as written → MRd (`HDR0=00000001`, `tkeep 0x0F`) because the +0x20 write lands on `TX_HDR0`; with fixes → the MWr from step 2. Both are matched by the predictor. Step 7: `+0x54` equals `+0x14`. Uniform-access bit-bash is deliberately not run on the WO registers. |
| **Coverage** | `cg_reg_access` — every offset × direction |
| **Pass** | Common criteria, on both RTL variants |

### TC-09 — Sidebands (`openpcie_sideband_test`)

| | |
|---|---|
| **Objective** | Verify sideband reflection into `ERR_STATUS`/`PHY_STATUS`, including credit exhaustion and fatal errors at low credit. |
| **Requirements** | CFG-001, CFG-002, CFG-003, TX-FLOW-001 |
| **Configuration** | `READY_ALWAYS`; timeout 20 ms |
| **Stimulus** | 1. `tx_buf_av` stepped through 32, 24, 16, 8, 3, 2, 1, 0, with `cfg_status` cycling 0x0000 / 0xFFFF / 0x0010 and `cfg_command = 0x0006`; at each step send one MemWr32 and read `PHY_STATUS`. 2. `cfg_status = 0xA5A5`, `err_fatal = 1`, `tx_buf_av = 32`; read `ERR_STATUS`; send one MemWr32. 3. `err_fatal = 1` with `tx_buf_av` at 16, 8, 3, 2, 1, 0; read `ERR_STATUS` each time. |
| **Checks** | `PHY_STATUS[5:0]` equals the driven `tx_buf_av`; `ERR_STATUS = {err_fatal, cfg_status}`; packets still transmit at zero credits; SOC-010 (no X on sidebands). |
| **Coverage** | `cg_sideband` — all `tx_buf_av` bins, `err_fatal` × credit cross, `cfg_status` zero/all-ones; `c_credit_exhausted`, `c_tx_while_no_credit` |
| **Pass** | Common criteria |

### TC-10 — Reset recovery (`openpcie_reset_test`)

| | |
|---|---|
| **Objective** | Verify that reset mid-traffic clears the DUT state and that the system recovers. Models the chip-level link-down (`resetn = ~user_reset && user_lnk_up`). |
| **Requirements** | RST-001, RST-002 |
| **Configuration** | `READY_ALWAYS`; timeout 20 ms |
| **Stimulus** | 1. 8 × MemWr32; `sync()`. 2. Pulse reset for 20 cycles. 3. Wait for firmware re-boot; `sync()`. 4. Read `RX_DATA` and `RX_STATUS`. 5. 8 × MemWr32; `sync()`. |
| **Checks** | Firmware re-boots; step 4 reads are 0; step 5 packets match the scoreboard. |
| **Coverage** | — |
| **Pass** | Common criteria |

### TC-11 — Mixed random traffic (`openpcie_random_test`)

| | |
|---|---|
| **Objective** | Regression workhorse: all traffic types interleaved under random backpressure. |
| **Requirements** | MIX-001, TX-PROTO-004, and every group incidentally |
| **Configuration** | `READY_RANDOM`, `ready_pct = 65`; timeout 60 ms |
| **Stimulus** | `n_iter` ∈ [50, 500] (default 150) iterations, each picking: MemWr32 (40 %), MemRd32 (20 %), outbound CplD (10 %), inbound CplD + `sync` (10 %), read of a random RX/ERR register (10 %), 1–3 random sideband changes (10 %). |
| **Checks** | Full environment: scoreboard, predictor, monitor and all SVA. |
| **Coverage** | All groups |
| **Expected** | **RTL as written: FAIL** (TX-PROTO-004). **With fixes: PASS.** |

---

## 6. Latest results

Vivado 2026.1 xsim, 5 seeds per test (seeds 1-5), 2026-10-20. Error counts,
checks per test and coverage per group: [results.md](results.md).

| TC | Test | RTL as written | With fixes |
|---|---|---|---|
| TC-01 | smoke | 5/5 PASS | 5/5 PASS |
| TC-02 | tx_directed | 5/5 PASS | 5/5 PASS |
| TC-03 | tx_random | 5/5 PASS | 5/5 PASS |
| TC-04 | tx_backpressure | 0/5 — TX-PROTO-004 (expected) | 5/5 PASS |
| TC-05 | tx_slow_sink | 0/5 — TX-PROTO-004 (expected) | 5/5 PASS |
| TC-06 | tx_burst_sink | 0/5 — TX-PROTO-004 (expected) | 5/5 PASS |
| TC-07 | rx_cpl | 5/5 PASS | 5/5 PASS |
| TC-08 | reg_access | 5/5 PASS (REG-004 alias observed and matched) | 5/5 PASS |
| TC-09 | sideband | 5/5 PASS | 5/5 PASS |
| TC-10 | reset | 5/5 PASS | 5/5 PASS |
| TC-11 | random | 0/5 — TX-PROTO-004 (expected) | 5/5 PASS |
| | **Total** | **35/55** | **55/55**, 0 warnings |

Merged functional coverage (fixed RTL, 55 runs): **100 %**
(`cg_reg_access`, `cg_tlp`, `cg_sideband` and `cg_packet_t1` each at 100 %;
`cg_tlp_diag` empty, as required).

---

## 7. Requirements traceability matrix

● = primary target of the test; ○ = also exercised and checked.

| Requirement | TC-01 | TC-02 | TC-03 | TC-04 | TC-05 | TC-06 | TC-07 | TC-08 | TC-09 | TC-10 | TC-11 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SMOKE-001 | ● | | | | | | | | | | |
| TX-FMT-001 | ● | ● | ● | ○ | ○ | ○ | | ○ | ○ | ○ | ○ |
| TX-FMT-002 | | ● | ● | ○ | ○ | ○ | | ○ | | | ○ |
| TX-FMT-003 | ○ | ● | ● | ○ | ○ | ○ | | ○ | ○ | ○ | ○ |
| TX-DATA-001 | | ● | ○ | | | | | | | | ○ |
| TX-RAND-001 | | | ● | | | | | | | | ○ |
| TX-TRIG-001 | | | | | | | | ● | | | |
| TX-TRIG-002 | | | | | | | | ● | | | |
| TX-PROTO-001 | ○ | ○ | ○ | ● | ● | ● | | ○ | ○ | ○ | ● |
| TX-PROTO-002 | | | | ● | ● | ● | | | | | ● |
| TX-PROTO-003 | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| TX-PROTO-004 | | | | ● | ● | ● | | | | | ● |
| TX-FLOW-001 | | | | | | | | | ● | | |
| RX-CAP-001 | | | | | | | ● | | | | ○ |
| RX-CAP-002 | | | | | | | ● | | | | ○ |
| RX-CAP-003 | | | | | | | ● | | | | |
| RX-CAP-004 | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| REG-001 | ○ | | | | | | ○ | ● | ○ | ○ | ○ |
| REG-002 | | | | | | | | ● | | | |
| REG-003 | | | | | | | | ● | | | |
| REG-004 | | | | | | | | ● | | | |
| CFG-001 | ○ | | | | | | | ○ | ● | | ○ |
| CFG-002 | ○ | | | | | | | ○ | ● | | |
| CFG-003 | | | | | | | | | ● | | ○ |
| RST-001 | | | | | | | | | | ● | |
| RST-002 | | | | | | | | | | ● | |
| CPU-001 | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| MIX-001 | | | | | | | | | | | ● |

TX-FLOW-002 is a software contract, documented in the verification plan
(§11.6); no test targets it.

---

## 8. Regression lists

| List | Tests | Seeds | Command |
|---|---|---|---|
| Sanity | TC-01 | 1 | `python scripts/run.py` |
| Full | TC-01..TC-11 | 5 | `python scripts/run.py --regress --seeds 5` |
| Full, fixed RTL | TC-01..TC-11 | 5 | `python scripts/run.py --fixes --regress --seeds 5 --cov-report` |
| Nightly | TC-01..TC-11 | ≥ 20, coverage on | `make regress SEEDS=20 COV=1` (VCS/Xcelium) |
