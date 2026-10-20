# openPCIE Root Complex — Tier 1 Verification Plan

| | |
|---|---|
| **Document** | VP-OPENPCIE-T1 |
| **Version** | 1.0 |
| **Date** | 2026-10-20 |
| **Status** | Released for review |
| **DUT** | `riscv_pcie_soc` - [rtl/openPCIE/2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv) |
| **RTL version** | openPCIE commit `6e48e11` (2026-07-27), pinned by the `rtl/openPCIE` submodule |
| **Companion documents** | [testplan.md](testplan.md) (test cases), [testplan.xlsx](testplan.xlsx) (tracking workbook), [tb_architecture.md](tb_architecture.md) (testbench architecture), [register_map.md](register_map.md) (DUT register map), [results.md](results.md) (regression and coverage results) |

### Revision history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-07-29 | Feature list, coverage model and expected findings |
| 0.2 | 2026-09-27 | Coverage closure on xsim (55.6 % → 100 %); REG-004 found |
| 0.3 | 2026-09-28 | RTL fixes prepared as patches for upstream; TX-FLOW-002 recorded |
| 1.0 | 2026-10-20 | Split into this plan and a separate testplan. RTL taken from the openPCIE submodule; one bound-interface RAM backdoor for all simulators; assertion failures reported through UVM |

---

## Contents

1. [Introduction](#1-introduction)
2. [Design under test](#2-design-under-test)
3. [Verification scope](#3-verification-scope)
4. [Verification strategy](#4-verification-strategy)
5. [Testbench architecture](#5-testbench-architecture)
6. [Feature list and verification requirements](#6-feature-list-and-verification-requirements)
7. [Checking plan](#7-checking-plan)
8. [Coverage plan](#8-coverage-plan)
9. [Regression strategy](#9-regression-strategy)
10. [Sign-off criteria and current status](#10-sign-off-criteria-and-current-status)
11. [Design findings](#11-design-findings)
12. [Risks and mitigations](#12-risks-and-mitigations)
13. [Open items and future tiers](#13-open-items-and-future-tiers)
14. [Appendix A — Tools and how to run](#appendix-a--tools-and-how-to-run)

---

## 1. Introduction

### 1.1 Purpose

This plan defines **what** must be verified in the openPCIE Tier 1 subsystem,
**how** it is verified (methodology, checkers, coverage) and **when** it is
done (sign-off criteria). The individual test cases are specified in
[testplan.md](testplan.md); this document is the requirements side of the
traceability chain:

```
Design feature (§6)  →  Check (§7)  →  Coverage item (§8)  →  Test case (testplan.md)
```

### 1.2 Audience

DV engineers running or extending the environment, RTL designers reviewing the
findings in §11, and reviewers signing off Tier 1.

### 1.3 References

| Ref | Document |
|---|---|
| [PCIe] | PCI Express Base Specification, Revision 2.1, PCI-SIG |
| [AXIS] | AMBA 4 AXI4-Stream Protocol Specification, ARM IHI 0051A |
| [UVM] | IEEE 1800.2-2020, Universal Verification Methodology |
| [SV] | IEEE 1800-2017, SystemVerilog |
| [PG054] | AMD/Xilinx 7 Series Integrated Block for PCI Express, PG054 (AXI4-Stream user interface) |
| [PicoRV32] | PicoRV32 native memory interface — <https://github.com/YosysHQ/picorv32> |
| [UPSTREAM] | chili-chips-ba/openPCIE — <https://github.com/chili-chips-ba/openPCIE> |

### 1.4 Acronyms

| Term | Meaning |
|---|---|
| TLP | Transaction Layer Packet |
| DW | Double word (32 bits) |
| CplD / Cpl | Completion with / without data |
| RAL | UVM register abstraction layer |
| SVA | SystemVerilog assertions |
| CRV | Constrained-random verification |
| DUT | Design under test |
| T1/T2/T3 | Verification tier (§3.3) |

---

## 2. Design under test

### 2.1 Function

`riscv_pcie_soc` is the open-source logic of the openPCIE Root Complex: a
PicoRV32 RV32I CPU with 8 KiB of RAM and a memory-mapped bridge that turns CPU
register writes into TLPs on a 64-bit AXI4-Stream transmit port, and captures
inbound completions from a receive port. In the chip top
(`RC_direct_opensource.sv`) it sits beside `host_bridge`, which wraps the
Xilinx `PCIE_2_1` hard block and GTP transceivers.

The bridge is reachable **only from the CPU**. The testbench therefore runs a
small mailbox firmware on the PicoRV32 (§5.2).

### 2.2 Interfaces

| Interface | Direction (DUT) | Width | Protocol | Notes |
|---|---|---|---|---|
| `clk`, `resetn` | in | 1 | — | 62.5 MHz `user_clk`; active-low synchronous reset |
| `s_axis_tx_*` (`tdata`, `tkeep`, `tlast`, `tvalid`, `tready`) | out (`tready` in) | 64 / 8 | AXI4-Stream [AXIS], [PG054] | Outbound TLPs |
| `m_axis_rx_*` (`tdata`, `tkeep`, `tlast`, `tvalid`, `tready`) | in (`tready` out) | 64 / 8 | AXI4-Stream | Inbound TLPs; `tready` tied high |
| `cfg_status` | in | 16 | level | Reflected in `ERR_STATUS[15:0]` |
| `cfg_command` | in | 16 | level | Declared, never read (CFG-003) |
| `cfg_msg_received_err_fatal` | in | 1 | level | Reflected in `ERR_STATUS[16]` |
| `tx_buf_av` | in | 6 | level | Reflected in `PHY_STATUS[5:0]` |

### 2.3 Register map (bridge base `0x3000_0000`)

| Offset | Name | Access | Content |
|---|---|---|---|
| `0x00` | `TX_HDR0` | WO | TLP header DW0 |
| `0x04` | `TX_HDR1` | WO | TLP header DW1 |
| `0x08` | `TX_HDR2` | WO | TLP header DW2 |
| `0x0C` | `TX_DATA` | WO | Payload DW; **the write triggers transmission** |
| `0x10` | `RX_STATUS` | RO | Captured completion status |
| `0x14` | `RX_DATA` | RO | Captured completion data DW |
| `0x18` | `RX_HDR_INFO` | RO | Captured completion header DW2 |
| `0x1C` | `ERR_STATUS` | RO | `{15'b0, err_fatal, cfg_status}` |
| `0x20` | `PHY_STATUS` | RO | `{24'b0, tx_state[1:0], tx_buf_av[5:0]}` |

Write-only registers read back 0. The read decode uses `addr[5]` and
`addr[4:2]` only, so the map aliases every 64 bytes (REG-003). The write
decode ignores `addr[5]` (REG-004, §11).

### 2.4 Clocks and resets

Single clock domain. `resetn` clears the TX FSM and the RX capture registers.
At the chip top `resetn = ~user_reset && user_lnk_up`, so link-down is
indistinguishable from reset; the reset test models that case.

---

## 3. Verification scope

### 3.1 In scope (Tier 1)

- CPU-bus decode of the bridge registers: read, write, write-only holes, aliasing
- TX path: header/payload assembly, 2-beat packet framing, `tkeep`/`tlast`
  generation, AXI4-Stream handshake under every backpressure profile
- RX path: completion detection, status/data/header capture, rejection of
  non-completion TLPs
- Sideband reflection: `cfg_status`, `err_fatal`, `tx_buf_av`
- Reset behaviour and recovery
- PicoRV32 native-bus handshake as seen by the bridge

### 3.2 Out of scope at this tier

| Item | Reason | Planned at |
|---|---|---|
| `PCIE_2_1` hard block, GTP transceivers, LTSSM, link training, speed change | Needs Xilinx encrypted simulation models | T2 / T3 |
| Multi-DW payloads, 4-DW headers | The T1 FSM emits exactly two beats | T2 |
| ECRC/TD, poisoned TLPs, `tuser` | Not connected at T1 | T2 |
| Completion timeout, tag management | No tag tracker in this RTL | T2 |
| PicoRV32 ISA compliance | Third-party core, verified upstream | — |
| Driver software (upstream `3.sw/main.c`) | Needs a RISC-V toolchain; out of DV scope | — |

### 3.3 Verification tiers

| Tier | DUT | Interfaces | Xilinx libs | Status |
|---|---|---|---|---|
| T0 | Leaf blocks (`stream_tx_path`, `speed_ctrl`, …) | block-level | no | not planned |
| **T1** | **`riscv_pcie_soc`** | AXIS + sidebands + CPU bus | **no** | **this plan** |
| T2 | `host_bridge` | AXIS + PIPE + serial | yes | not started |
| T3 | `RC_direct_opensource` + endpoint model | serial | yes | not started |

### 3.4 Assumptions

- The PicoRV32 core is functionally correct; it is used as a stimulus engine.
- The openPCIE RTL (submodule `rtl/openPCIE`) is not edited. Changes needed to simulate are applied by
  the patch layer (`scripts/rtl_patches.py`) into `build/rtl_patched/` (§11).
- `tx_buf_av` is informational only; the DUT never consults it before sending
  (TX-FLOW-001).

---

## 4. Verification strategy

### 4.1 Methodology

| Technique | Applied to |
|---|---|
| UVM 1.2 / IEEE 1800.2 class-based environment | Whole testbench |
| Directed tests | Smoke, packet shapes, walking-ones, register map, reset |
| Constrained-random stimulus with multiple seeds | TLP mix, backpressure, sideband changes |
| Reference model (predictor) + scoreboard | All TX packets and all register readbacks |
| Assertion-based verification (SVA) | AXI4-Stream protocol, internal FSM invariants, CPU handshake |
| Functional coverage | Registers, TLP fields, sidebands, packet shapes |
| Static checks before simulation | Lint cross-checks, slang parse/elaborate, firmware self-test |

### 4.2 Strategy per feature group

| Group | Stimulus | Checking | Closure |
|---|---|---|---|
| TX framing | Directed shapes + random TLP kinds | Predictor ↔ scoreboard, SVA `SOC-002..005` | `cg_tlp`, `cg_packet_t1` |
| TX handshake | Four sink profiles (always / random / slow / burst) | SVA `AXIS-001/002`, monitor, scoreboard | Stall cover points; responder stall-count warning |
| RX capture | Injected Cpl/CplD with all statuses; non-Cpl TLP | Readback vs predictor | `cg_reg_access` |
| Registers | RAL frontdoor through firmware | RAL mirror, scoreboard readback | `cg_reg_access` (offset × direction) |
| Sidebands | Static and random sideband sequences | Readback vs predictor | `cg_sideband` |
| Reset | Mid-traffic reset pulse | Directed checks + re-boot | Test pass |

### 4.3 Independence of checking

The predictor builds the expected TLP from **observed CPU bus writes**, not from
the sequence's intent. A firmware or mailbox defect therefore appears as a
mismatch instead of moving stimulus and expectation together. The RTL fixes
are switched by one define, `OPENPCIE_RTL_FIXES`, which the predictor also
reads so both sides stay in step.

---

## 5. Testbench architecture

Full detail and diagrams are in [tb_architecture.md](tb_architecture.md).

### 5.1 Components

| Component | File | Role |
|---|---|---|
| `tb_top` | [tb/top/tb_top.sv](../tb/top/tb_top.sv) | Clock/reset, DUT, interfaces, AXIS SVA, config DB, `run_test()` |
| Binds | [tb/top/openpcie_bind.sv](../tb/top/openpcie_bind.sv) | CPU-bus observer, RAM backdoor and white-box SVA bound into the DUT |
| `openpcie_env` | [tb/env/openpcie_env.svh](../tb/env/openpcie_env.svh) | Builds agents, predictor, scoreboard, coverage, RAL, mailbox |
| AXIS agent ×2 | [tb/agents/axis_agent/](../tb/agents/axis_agent/) | `rx_agent` MASTER drives inbound TLPs; `tx_agent` SLAVE drives `tready` in four modes |
| Config agent | [tb/agents/cfg_agent/](../tb/agents/cfg_agent/) | Drives `cfg_status`, `cfg_command`, `err_fatal`, `tx_buf_av` |
| CPU agent | [tb/agents/cpu_agent/](../tb/agents/cpu_agent/) | Passive observer of the PicoRV32 bus |
| Firmware mailbox | [tb/env/openpcie_fw_mailbox.svh](../tb/env/openpcie_fw_mailbox.svh) | Posts commands into SoC RAM and waits for ACK |
| RAM backdoor | [tb/top/openpcie_ram_bkdr_if.sv](../tb/top/openpcie_ram_bkdr_if.sv) | Bound interface with the DUT `ram` on a `ref` port; no DPI or HDL-access flags |
| Predictor | [tb/env/openpcie_predictor.svh](../tb/env/openpcie_predictor.svh) | Shadow TX header registers, RX capture FSM and sidebands |
| Scoreboard | [tb/env/openpcie_scoreboard.svh](../tb/env/openpcie_scoreboard.svh) | In-order TX packet compare; register readback compare; end-of-test checks |
| RAL | [tb/ral/openpcie_ral.svh](../tb/ral/openpcie_ral.svh) | 9 registers; TX registers marked WO |
| Coverage | [tb/env/openpcie_soc_coverage.svh](../tb/env/openpcie_soc_coverage.svh), [openpcie_axis_coverage.svh](../tb/agents/axis_agent/openpcie_axis_coverage.svh) | §8 |
| Assertions | [tb/sva/openpcie_axis_sva.sv](../tb/sva/openpcie_axis_sva.sv), [tb/sva/openpcie_soc_sva.sv](../tb/sva/openpcie_soc_sva.sv) | §7.2 |

### 5.2 Stimulus paths

1. **Firmware mailbox.** A 43-instruction RV32I loop
   ([tb/fw/mailbox_fw.s](../tb/fw/mailbox_fw.s)) polls a structure at RAM `0x1F00`.
   The testbench writes commands there through the backdoor; the CPU performs
   the real bus writes. Commands: `SEND_TLP`, `WRITE_REG`, `READ_REG`, `NOP`.
   The firmware is assembled and self-tested in Python
   ([tb/fw/build_fw.py](../tb/fw/build_fw.py)); no RISC-V toolchain is needed.
2. **RX agent** drives inbound TLPs on `m_axis_rx_*`.
3. **Config agent** drives the sideband inputs.

---

## 6. Feature list and verification requirements

Priority: **P1** must be verified for sign-off; **P2** should be verified;
**P3** documents behaviour.

| ID | Requirement | Pri | RTL reference | Check | Coverage | Test(s) |
|---|---|---|---|---|---|---|
| **SMOKE-001** | Firmware boots, mailbox handshake completes, one TLP traverses TX | P1 | — | Boot magic; scoreboard | — | TC-01 |
| **TX-FMT-001** | 3-DW header + 1 payload DW → 2 beats, final `tkeep=0xFF` | P1 | `riscv_pcie_soc.sv:195-211` | Predictor/scoreboard; `SOC-003` | `x_fmt_keep.ok_data_full` | TC-01, TC-02, TC-03 |
| **TX-FMT-002** | 3-DW header, no payload (`Fmt[1]=0`) → final `tkeep=0x0F` | P1 | `:204` | Predictor/scoreboard; `SOC-003` | `x_fmt_keep.ok_nodata_partial` | TC-02, TC-03 |
| **TX-FMT-003** | First beat always `tkeep=0xFF`, `tlast=0` | P1 | `:197-199` | `SOC-004`, `SOC-002` | `cg_packet_t1` | all TX tests |
| **TX-DATA-001** | Beat 0 = `{HDR1,HDR0}`, beat 1 = `{DATA,HDR2}`; no bit stuck, swapped or dropped | P1 | `:196,203` | Scoreboard | — | TC-02 (walking-ones ×32) |
| **TX-RAND-001** | All Tier 1 TLP kinds (MEM, IO, CFG0, CFG1, CPL) and Lengths 1–1024 framed correctly | P1 | `:195-211` | Scoreboard | `cg_tlp.cp_type`, `cp_len`, `x_type_fmt` | TC-03 |
| **TX-TRIG-001** | Only a write to `TX_DATA` starts a transmit; header writes are inert | P1 | `:180-185` | Predictor; `build_fw.py` model | — | TC-08 |
| **TX-TRIG-002** | Header registers are sticky across transmits | P2 | `:177-179` | Scoreboard | — | TC-08 |
| **TX-PROTO-001** | `tvalid` held until `tready` | P1 | [AXIS] §2.2.1 | `AXIS-001` | `c_stall*` | all TX tests |
| **TX-PROTO-002** | Payload stable while stalled | P1 | [AXIS] §2.2.1 | `AXIS-002`, monitor | `c_stall_on_first/last` | TC-04, TC-05, TC-06, TC-11 |
| **TX-PROTO-003** | `tkeep` contiguous; partial only on `tlast` | P1 | [AXIS] Table 2-2 | `AXIS-004/005` | `cg_packet_t1` | all TX tests |
| **TX-PROTO-004** | Transmit survives backpressure without losing a beat | P1 | `:200,208` | `AXIS-002` + scoreboard | `c_tx_stall_in_c1/c2` | TC-04, TC-05, TC-06, TC-11 — **fails on RTL as written (§11)** |
| **TX-FLOW-001** | Behaviour with `tx_buf_av = 0` documented (DUT does not gate on credits) | P3 | `:153` | Directed readback | `c_tx_while_no_credit`, `cp_tx_buf_av.empty` | TC-09 |
| **TX-FLOW-002** | Software must poll `tx_state==IDLE` before each send (no HW interlock) | P3 | `:180-185` | Documented contract | — | — (§11.6) |
| **RX-CAP-001** | Completion status captured from `tdata[47:45]` | P1 | `:217-219` | Readback vs predictor | `cg_reg_access` | TC-07 |
| **RX-CAP-002** | Phase 1 captures DW2 → `RX_HDR_INFO`, DW3 → `RX_DATA` | P1 | `:223-224` | Readback vs predictor | `cg_reg_access` | TC-07 |
| **RX-CAP-003** | A non-completion inbound TLP leaves capture registers unchanged | P2 | `:217` | Predictor mirrors RTL | — | TC-07 |
| **RX-CAP-004** | `m_axis_rx_tready` is tied high | P2 | `:233` | `SOC-006` | — | all |
| **REG-001** | All five readable registers decode correctly | P1 | `:243-249` | RAL + scoreboard | `x_offset_dir` | TC-08 |
| **REG-002** | TX registers are write-only; reads return 0 | P1 | `:248` | Directed check | `x_offset_dir` | TC-08 |
| **REG-003** | Read decode aliases every 64 bytes | P3 | `:239-249` | Directed alias check | `cp_offset.aliased` | TC-08 |
| **REG-004** | A write to a read-only register has no side effect | P2 | `:175` | Scoreboard packet compare | `x_offset_dir` | TC-08 — **fails on RTL as written (§11)** |
| **CFG-001** | `ERR_STATUS = {err_fatal, cfg_status}` | P1 | `:152` | Readback vs predictor | `cg_sideband` | TC-09 |
| **CFG-002** | `PHY_STATUS[5:0]` tracks `tx_buf_av` | P1 | `:153` | Readback (masked) | `cp_tx_buf_av` | TC-09 |
| **CFG-003** | `cfg_command` has no effect (port unused) | P3 | `:60` | `SOC-010` | — | TC-09 |
| **RST-001** | Reset clears the RX capture registers and the TX FSM | P1 | `:157-167` | Directed readback | — | TC-10 |
| **RST-002** | CPU re-boots and the datapath works after reset | P1 | — | Re-boot handshake + traffic | — | TC-10 |
| **CPU-001** | PicoRV32 bus handshake is honoured by the bridge | P2 | `:172-173,256` | `SOC-008/009/011` | — | all |
| **MIX-001** | Sustained mixed traffic under random backpressure | P1 | — | Full environment | all groups | TC-11 |

RTL references are line numbers in
[riscv_pcie_soc.sv](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv).

---

## 7. Checking plan

### 7.1 Transaction-level checkers

| ID | Checker | What it flags |
|---|---|---|
| `SCBD/TX` | Scoreboard | Observed TX packet ≠ predicted (beat count, `tdata`, `tkeep`, `tlast`), unexpected or missing packet |
| `SCBD/RD` | Scoreboard | Register readback ≠ predictor shadow |
| `SCBD` (EOT) | Scoreboard | Leftover expected/observed items, or no TX packet checked when TX activity is required |
| `AXIS/PROTO` | AXIS monitor | Handshake/stability violations that need packet history |
| `SVA/AXIS`, `SVA/SOC` | Assertion modules | Any assertion in 7.2 failing |
| `FWBOX` | Mailbox | Boot timeout, command timeout, handshake violation (`CMD` not cleared before `ACK`) |
| Responder | `tx_agent` | `UVM_WARNING` if configured to stall but never stalled (proves backpressure was applied) |

### 7.2 Assertions

**AXI4-Stream** ([openpcie_axis_sva.sv](../tb/sva/openpcie_axis_sva.sv)), on both TX and RX:

| ID | Property |
|---|---|
| AXIS-001 | `tvalid` stays high until `tready` |
| AXIS-002 | `tdata`/`tkeep`/`tlast` stable while stalled |
| AXIS-003 | A valid beat carries at least one byte |
| AXIS-004 | `tkeep` is contiguous from bit 0 |
| AXIS-005 | Only the last beat may be partial |
| AXIS-006 | No X/Z on control or data while `tvalid` |
| AXIS-007 | `tvalid`/`tready` never X out of reset |

**White-box** ([openpcie_soc_sva.sv](../tb/sva/openpcie_soc_sva.sv)), bound into the DUT:

| ID | Property |
|---|---|
| SOC-001 | `tx_state` only takes legal encodings |
| SOC-002 | A packet is exactly two beats |
| SOC-003 | Final `tkeep` ∈ {`0x0F`, `0xFF`} and agrees with `Fmt[1]` |
| SOC-004 | First beat `tkeep = 0xFF` |
| SOC-005 | No `tvalid` while `tx_state == IDLE` |
| SOC-006 | `m_axis_rx_tready` tied high |
| SOC-007 | `rx_phase` never X/Z |
| SOC-008 | CPU request stable until `mem_ready` |
| SOC-009 | `mem_ready` traceable to a request this or last cycle |
| SOC-010 | `cfg_command`, `cfg_status`, `tx_buf_av` never X/Z |
| SOC-011 | Trailing `mem_ready` pulse lasts at most one cycle |

Both assertion modules report failures with `uvm_report_error` (IDs `SVA/AXIS`
and `SVA/SOC`), so an assertion failure fails the test through the normal UVM
error count on every simulator. Each assertion instance reports its first 20
failures and then counts silently, so a systemic failure cannot bury the log.

---

## 8. Coverage plan

### 8.1 Functional coverage model

| Covergroup | Coverpoints / crosses | Goal | Weight |
|---|---|---|---|
| `cg_reg_access` | offset (9 named + `aliased`), direction, `offset × direction` | 100 % | 1 |
| `cg_tlp` | Type (mem, io, cfg0, cfg1, cpl), Fmt (3-DW nodata/data), Length (1, 2–8, 9–64, 65–1023, 1024), final `tkeep`, `Fmt × tkeep`, `Type × Fmt` | 100 % | 1 |
| `cg_sideband` | `tx_buf_av` (0, 1–3, 4–31, 32–63), `err_fatal`, `cfg_status` (0, all-ones, other), `credit × err_fatal` | 100 % | 1 |
| `cg_packet_t1` (tx, rx) | 2 beats; final `tkeep` 0x0F / 0xFF; 12 / 16 bytes | 100 % | 1 |
| `cg_packet` (tx, rx) | All packet shapes (for T2 reuse) | tracked | 0 at T1 |
| `cg_tlp_diag` | Non-conforming Fmt/`tkeep` pairs | **must stay 0 %** | 0 |

### 8.2 Coverage exclusions

| Item | Justification |
|---|---|
| `cp_fmt` 4-DW formats, `cp_type.msg` (`ignore_bins`) | The T1 bridge emits exactly three header DWs, so these cannot be sent as well-formed TLPs |
| `x_fmt_keep` non-conforming pairs (`ignore_bins`) | Moved to `cg_tlp_diag`, where any hit is a DUT bug |
| `cg_packet` shapes other than 2 beats / 12–16 bytes (weight 0) | Unreachable at T1; `tier1_shapes` knob restores them for T2 |

### 8.3 Assertion cover points

`c_stall`, `c_stall_2cyc`, `c_stall_5cyc`, `c_stall_on_first`,
`c_stall_on_last`, `c_btb_packets`, `c_partial_last`, `c_full_last`,
`c_tx_full_packet`, `c_tx_stall_in_c1`, `c_tx_stall_in_c2`,
`c_rx_phase_toggle`, `c_credit_exhausted`, `c_tx_while_no_credit`.

`c_stall_on_first` is the evidence that TX-PROTO-004 was actually exercised. Goal:
every cover point hit at least once.

### 8.4 Code coverage

| Metric | Goal | Exclusions |
|---|---|---|
| Line | ≥ 95 % on `riscv_pcie_soc` | PicoRV32 (third-party) |
| Branch / condition | ≥ 90 % | unreachable `default` arms, with review |
| FSM (`tx_state`, `rx_phase`) | 100 % states and legal transitions | encoding `2'd3` (SOC-001) |
| Toggle | ≥ 90 % on ports | `cfg_command` (unused, CFG-003) |

---

## 9. Regression strategy

| Suite | Content | Seeds | When |
|---|---|---|---|
| **Sanity** | `openpcie_smoke_test` | 1 | Every change, before commit |
| **Full** | All 11 tests | 5 | Every change to RTL or TB |
| **Nightly** | All 11 tests, coverage on | ≥ 20 | Nightly |
| **Fixed-RTL** | All 11 tests with `--fixes` / `FIXES=1` | same as above | Alongside each suite while fixes are not upstream |

Before every simulation, both flows build and self-test the firmware and
regenerate the patch layer. The Makefile flow also runs the lint checks. A test **passes** only if the UVM report
server prints `TEST PASSED`: no `UVM_ERROR` or `UVM_FATAL`, no assertion failure,
and no scoreboard leftovers.

---

## 10. Sign-off criteria and current status

Status as of 2026-10-20, Vivado 2026.1 xsim.

| # | Criterion | Status |
|---|---|---|
| 1 | All P1/P2 requirements in §6 have a passing test, or a failure that is traced to a recorded finding in §11 | Met |
| 2 | Always-ready tests pass on ≥ 20 seeds | Partial — 7/7 tests pass on 5 seeds |
| 3 | The four stalling-sink tests either pass (fixed RTL) or fail **only** with errors traceable to TX-PROTO-004 | Met - all 4163 errors in the 20 failing runs are `AXIS/PROTO`, `SVA/AXIS`, `SVA/SOC` or `SCBD/TX` from TX-PROTO-004; 55/55 pass with fixes |
| 4 | Functional coverage ≥ 95 % with `x_fmt_keep` 100 % and `cg_tlp_diag` empty | Met — 100 % merged, diagnostic group empty |
| 5 | Every assertion cover point hit | Open — xsim ignores `cover property`; needs VCS or Xcelium |
| 6 | Code coverage goals in §8.4 | Open — not yet collected |
| 7 | Static checks clean (lint, slang, firmware self-test) | Met |
| 8 | All findings in §11 reviewed with the RTL owner | Partial — patches prepared in `patches/`, not yet submitted |

**Latest regression (11 tests × 5 seeds):** RTL as written 35/55; with fixes
**55/55**, 0 warnings, **100 %** functional coverage. Per-test results are in
[testplan.md §6](testplan.md#6-latest-results).

---

## 11. Design findings

| ID | Severity | Title | Status | Fix |
|---|---|---|---|---|
| TX-PROTO-004 | **High** | TX FSM samples `tready` one cycle early; beat 0 is lost under backpressure | Confirmed in simulation | [0002 patch](../patches/0002-tx-fsm-honour-axis-handshake.patch) |
| REG-004 | Medium | Register writes ignore `addr[5]`: a write to `PHY_STATUS` overwrites `TX_HDR0`, and a write to `+0x2C` starts a transmit | Confirmed in simulation | [0003 patch](../patches/0003-bridge-write-decode-use-addr5.patch) |
| RTL-SIM-001 | Medium (tooling) | `ram` written by both `$readmemh` and `always_ff`; VCS refuses to elaborate | Confirmed | [0001 patch](../patches/0001-ram-always-instead-of-always_ff.patch); applied by the patch layer |
| CFG-003 | Low | `cfg_command` input is never read and unconnected at chip top | Documented | — |
| RTL-SIM-002 | Low | RAM path re-arms `mem_ready` for one extra cycle | Documented, benign | optional `&& !ram_ready_reg` |
| TX-FLOW-002 | Info | No hardware busy interlock on `TX_DATA`; software must poll | Documented contract | — |
| REG-003 | Info | Read decode aliases every 64 bytes | Documented limitation | — |
| RX-CAP-003 | Info | RX capture FSM cannot resynchronise to packet boundaries | Documented limitation | — |
| FW-001 | Info | Initial stack pointer (`0x2000`) is one word past the RAM | Latent (mailbox firmware uses no stack) | — |

### 11.1 TX-PROTO-004 — TX FSM samples `tready` one cycle early

[`riscv_pcie_soc.sv:195-211`](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv#L195-L211):
`tvalid` and `tdata` are registered, but the state transition tests
`s_axis_tx_tready` in the cycle that *schedules* them. With an always-ready
sink the two off-by-one errors cancel. Under backpressure, beat 1 overwrites
beat 0 before it is accepted, and the TLP header never reaches the link:

```
[PRED]       expect TX packet #1: [0]=020000044a000001/ff [1]=8878a1c501000000/ff
[AXIS/PROTO] tx: payload changed during a stall -
             was data=020000044a000001 keep=ff last=0,
             now data=8878a1c501000000 keep=ff last=1
```

The asymmetry is the diagnosis: the four stalling-sink tests fail on every
seed and the seven always-ready tests pass. The fix (advance only on
`tvalid && tready`) turns all of them green.

### 11.2 REG-004 — writes ignore `addr[5]`

The read decode uses `addr[5]` to select `PHY_STATUS`; the write decode
([`:175`](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv#L175)) uses only
`addr[4:2]`. TC-08 writes an MRd header through `+0x20`. On the RTL as written,
the packet that follows goes out as that MRd (`HDR0=00000001`, final
`tkeep=0x0F`), and the predictor, which models the RTL decode, matches it. With
the fix, the write is ignored and the MWr goes out. Mutation-tested: reverting the
predictor makes the same test fail with `SCBD/TX`.

### 11.3 RTL-SIM-001 — `ram` driven by `$readmemh` and `always_ff`

IEEE 1800-2017 §9.2.2.4 forbids any other process writing a variable assigned
in `always_ff`. VCS reports `Error-[ICPD]` and will not elaborate the design,
with or without a testbench. Changing that one block to `always` has no effect
on simulation or synthesis behaviour. The patch layer applies this fix
unconditionally.

### 11.4 RTL-SIM-002 — RAM `mem_ready` re-arm

The RAM ready logic lacks the `!ready_reg` guard that the bridge path has, so
`mem_ready` stays high for one cycle after `mem_valid` drops. PicoRV32 ignores
`mem_ready` without `mem_valid`, so this is benign. SOC-009 and SOC-011 bound it.

### 11.5 CFG-003, REG-003, RX-CAP-003

These are documented limitations. The predictor models each one faithfully, so
the suite measures the RTL as written.

### 11.6 TX-FLOW-002 — software contract

A write to `TX_DATA` during an in-flight packet silently drops the new
packet. The upstream driver polls `PHY_STATUS[7:6] == IDLE` before every
send; the mailbox firmware does not need to, because every configured sink
drains a packet faster than one mailbox round trip.

---

## 12. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Firmware-based stimulus hides a CPU or mailbox bug behind a timeout | Slow debug | Firmware self-test in Python before every run; mailbox dumps its state on timeout; predictor fed from the observed bus |
| xsim limitations: no `cover property`, solver gaps, no `uvm_hdl` DPI | Incomplete evidence | Bound-interface backdoor; procedural randomisation for TLP kind/Length; assertion covers scheduled on VCS/Xcelium |
| Random backpressure never stalls the first beat | False pass on TX-PROTO-004 | Responder warns when configured to stall but never did; `c_stall_on_first` cover point |
| Tests weakened to make them pass | Bug masked | Findings recorded with expected symptoms; fixes are an explicit `--fixes` switch, off by default |
| Upstream RTL changes | Patch anchors break | `rtl_patches.py` fails loudly when an anchor is not found; `make_upstream_patches.py --check` |

---

## 13. Open items and future tiers

| # | Item | Owner | Target |
|---|---|---|---|
| 1 | Submit the three patches in `patches/` | RTL | — |
| 2 | Collect assertion cover points and code coverage on VCS or Xcelium | DV | Sign-off |
| 3 | Run the nightly suite at ≥ 20 seeds | DV | Sign-off |
| 4 | Optional: make `mailbox_fw.s` poll `tx_state`, and add a long-stall test | DV | Post-sign-off |
| 5 | Tier 2: `host_bridge` with Xilinx simulation libraries; PIPE agent | DV | Next tier |
| 6 | Tier 3: full chip with an endpoint model | DV | Next tier |

---

## Appendix A — Tools and how to run

| Tool | Version used | Purpose |
|---|---|---|
| Vivado simulator (xsim) | 2026.1 | Simulation and functional coverage |
| VCS / Xcelium | supported by `sim/Makefile`, not yet run | Simulation, assertion and code coverage |
| slang (pyslang) | 11.0.0 | Parse and elaborate check (`scripts/slang_check.py`) |
| Verible | v0.0-4296-g0f262651 | SystemVerilog syntax and style lint (CI) |
| Python | 3.12 | Firmware assembler/ISS, runners, checks |

```bash
python scripts/run.py                                             # sanity
python scripts/run.py --regress --seeds 5 --logdir regress_nofix  # full, RTL as written
python scripts/run.py --fixes --regress --seeds 5 --logdir regress_fixed --cov-report

cd sim && make regress SEEDS=20 COV=1 && make cov-report              # VCS nightly
```
