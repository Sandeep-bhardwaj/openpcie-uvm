# Testbench architecture

This document describes how the Tier 1 environment is built: what the DUT is,
how stimulus reaches it, how results are checked, and why the main design
choices were made. For what is verified and the sign-off status, see
[verification_plan.md](verification_plan.md); for the individual tests, see
[testplan.md](testplan.md).

## Contents

1. [Choice of DUT](#1-choice-of-dut)
2. [Block diagram](#2-block-diagram)
3. [Source tree](#3-source-tree)
4. [Stimulus paths](#4-stimulus-paths)
5. [Checking](#5-checking)
6. [Coverage collection](#6-coverage-collection)
7. [Build and run flow](#7-build-and-run-flow)
8. [Design decisions](#8-design-decisions)
9. [Extending to Tier 2](#9-extending-to-tier-2)

---

## 1. Choice of DUT

The openPCIE chip top, `RC_direct_opensource`, has only differential serial
pairs, a reference clock, reset and LEDs on its ports. There is no bus for an
agent to drive, and the design instantiates Xilinx primitives (`PCIE_2_1` in
[silicon_core.sv:806](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/pcie/silicon_core.sv#L806),
`GTPE2_CHANNEL` in
[lane_xcvr.sv:325](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/pcie/lane_xcvr.sv#L325),
`GTPE2_COMMON`, `MMCME2_ADV`, `RAMB36E1`) that only simulate with the
encrypted Vivado libraries.

Verification is therefore split into tiers:

| Tier | DUT | Interfaces | Xilinx libraries | Status |
|---|---|---|---|---|
| T0 | `stream_tx_path`, `stream_rx_path`, `speed_ctrl`, `init_ctrl`, ... | AXIS / TRN / DRP | no | not planned |
| **T1** | **`riscv_pcie_soc`** | AXI4-Stream x2, sidebands, CPU bus | no | **this repository** |
| T2 | `host_bridge` | AXIS + PIPE + serial | yes | not started |
| T3 | `RC_direct_opensource` + endpoint model | serial | yes | not started (upstream `5.sim` could be reused) |

`riscv_pcie_soc` is where the project's own open-source logic lives: a
PicoRV32 CPU, its 8 KiB RAM and the bridge that turns CPU register writes into
TLPs. It has clean bus boundaries on both sides, uses no vendor primitives and
simulates quickly. The agents and sequences are written so that Tier 2 can
reuse them.

---

## 2. Block diagram

```
                 RAM backdoor (openpcie_ram_bkdr_if, bound onto dut.ram)
   openpcie_fw_mailbox ─────────────────┐            openpcie_rst_if
        ▲                               │                   │
        │ send_tlp / read_reg /         ▼                   ▼
        │ write_reg / sync    ┌────────── DUT: riscv_pcie_soc ──────────┐
        │                     │                                         │
        │                     │  PicoRV32 ───── mem bus ───── bridge    │
        │                     │      │              ▲                   │
        │                     │  ram[2048]          │ bind              │
        │                     └─────────────────────┼───────────────────┘
        │                          ▲                │            │
        │              m_axis_rx_* │                │ cpu_if     │ s_axis_tx_*
        │                          │                │            ▼
   ┌────┴─────┐            ┌───────┴──┐      ┌──────┴───┐  ┌──────────┐
   │  vseqr   │───────────▶│ rx_agent │      │cpu_agent │  │ tx_agent │
   │          │            │ (MASTER) │      │(PASSIVE) │  │ (SLAVE)  │
   └────┬─────┘            └────┬─────┘      └────┬─────┘  └────┬─────┘
        │                       │ beat_ap         │ ap          │ ap
        │                       ▼                 ▼             │
        │   cfg_agent ──ap──▶ ┌───────────────────────┐         │
        │                     │      predictor        │         │
        │                     │  TX header shadow     │         │
        │                     │  RX capture model     │         │
        │                     │  sideband shadow      │         │
        │                     └──────────┬────────────┘         │
        │                       expected │                      │ observed
        │                                ▼                      │
        │                     ┌───────────────────────┐         │
        └────────────────────▶│      scoreboard       │◀────────┘
                              │  TX packet compare    │
                              │  register readback    │
                              └───────────────────────┘
```

---

## 3. Source tree

| Directory | Contents |
|---|---|
| `tb/common/` | `openpcie_types_pkg` (DUT constants, register map, mailbox layout, virtual-interface typedefs); `openpcie_tlp_pkg` (TLP sequence item: header fields, packing into AXIS beats, unpacking) |
| `tb/agents/axis_agent/` | AXI4-Stream agent used three ways: master (drives a stream), slave (drives `tready` with a backpressure profile), passive. Interface, item, driver, responder, monitor, coverage, config |
| `tb/agents/cfg_agent/` | Sideband agent: interface, driver, monitor, static and random sequences for `cfg_status`, `cfg_command`, `cfg_msg_received_err_fatal`, `tx_buf_av` |
| `tb/agents/cpu_agent/` | Passive monitor of the PicoRV32 native memory bus; its interface is bound into the DUT |
| `tb/ral/` | Register model (9 registers) and the firmware frontdoor that routes RAL accesses through the mailbox |
| `tb/env/` | Environment, its configuration, firmware mailbox, predictor, scoreboard, SoC-level coverage, virtual sequencer |
| `tb/seq/` | Base virtual sequence (helpers: `send_tlp`, `read_reg`, `write_reg`, `sync`, `inject_rx`, TLP builders) and the sequence library |
| `tb/tests/` | Base test and the 11 tests |
| `tb/sva/` | AXI4-Stream protocol assertions; white-box assertions bound into the DUT |
| `tb/top/` | `tb_top`, the bind file, reset interface, RAM backdoor interface |
| `tb/fw/` | Mailbox firmware (RV32I assembly), its builder and self-test, and a small RV32I assembler and instruction-set simulator |

---

## 4. Stimulus paths

### 4.1 Firmware mailbox

The bridge registers sit behind the CPU, so nothing outside the SoC can reach
them. `riscv_pcie_soc` also loads its RAM with an unconditional
`$readmemh("firmware.hex", ram)`. The environment uses this: it runs a small
firmware ([tb/fw/mailbox_fw.s](../tb/fw/mailbox_fw.s), 43 instructions) that
waits for commands in a mailbox in RAM and performs the register accesses on
the CPU bus.

Mailbox layout (byte addresses in the SoC RAM):

| Address | Name | Written by | Meaning |
|---|---|---|---|
| `0x1F00` | `CMD` | TB, cleared by FW | Command to execute (0 = idle) |
| `0x1F04`..`0x1F10` | `ARG0`..`ARG3` | TB | Arguments |
| `0x1F14` | `RSP` | FW | Result (register read value) |
| `0x1F18` | `ACK` | FW | Completion counter, incremented after each command |
| `0x1F1C` | `ALIVE` | FW | `0x1E5D0001`, written once at boot |

Commands:

| Code | Command | Action |
|---|---|---|
| 1 | `SEND_TLP` | Write `ARG0..ARG2` to `TX_HDR0..2`, then `ARG3` to `TX_DATA` (which starts the transmit) |
| 2 | `READ_REG` | `RSP = [0x3000_0000 + ARG0]` |
| 3 | `WRITE_REG` | `[0x3000_0000 + ARG0] = ARG1` |
| 4 | `NOP` | No side effect; used as an ordering barrier (`sync()`) |

Handshake: the TB writes the arguments, then `CMD`; the firmware executes the
command, writes `RSP`, clears `CMD`, and only then increments `ACK`. Waiting
for `ACK` to change therefore guarantees that the mailbox is free again. At
boot the firmware clears the mailbox before it writes `ALIVE`, so a command
posted as soon as `ALIVE` appears cannot be wiped.

The TB reaches the RAM through
[openpcie_ram_bkdr_if](../tb/top/openpcie_ram_bkdr_if.sv). The interface is
bound into `riscv_pcie_soc` with the DUT's `ram` array connected to a `ref`
port, and `tb_top` places it in the config DB as `bkdr_vif`. Accesses are
plain assignments, not forces, so the firmware stays free to write the same
words. This needs neither `uvm_hdl_deposit` nor HDL-access elaboration flags,
so the same code runs on xsim (whose bundled UVM leaves out the HDL backdoor
DPI), VCS and Xcelium.

No RISC-V toolchain is needed. [tb/fw/rv32.py](../tb/fw/rv32.py) is an RV32I
assembler and instruction-set simulator, and
[tb/fw/build_fw.py](../tb/fw/build_fw.py) assembles the firmware, runs it
against a Python model of the bridge (24 checks, about 1800 instructions) and
only then writes `build/fw/firmware.hex`. Firmware bugs are found there rather
than inside a simulation.

### 4.2 RX agent

`openpcie_axis_agent` in master mode drives `m_axis_rx_*`. Sequences build a
TLP with `openpcie_tlp` and call `inject_rx()`, optionally with an idle gap
before it.

### 4.3 Sideband agent

`openpcie_cfg_agent` drives `cfg_status`, `cfg_command`,
`cfg_msg_received_err_fatal` and `tx_buf_av`. Defaults are applied at time 0,
so the DUT never samples X before the first clock edge.

---

## 5. Checking

### 5.1 Reference model

The obvious approach, where the sequence tells the scoreboard what it sent,
couples stimulus and expectation: a firmware or mailbox bug changes both and
the scoreboard stays green. Instead, `openpcie_cpu_if` is bound into the DUT
and the predictor watches the real CPU bus. It keeps:

- shadow copies of `TX_HDR0..2`, and builds the expected 2-beat packet when
  `TX_DATA` is written;
- a model of the RX capture state machine, fed by the RX monitor;
- shadow sideband values, fed by the sideband monitor.

The predictor decodes register writes exactly as the RTL does (including the
REG-004 behaviour). When the optional RTL fixes are compiled in, the define
`OPENPCIE_RTL_FIXES` switches the predictor to the fixed decode.

### 5.2 Checker layers

| Layer | Detects | Source |
|---|---|---|
| SVA, protocol | `tvalid` dropped before `tready`, payload changed during a stall, bad `tkeep`, X on control | [openpcie_axis_sva.sv](../tb/sva/openpcie_axis_sva.sv) |
| SVA, white-box | illegal FSM state, wrong beat count, `rx_tready` not tied high, CPU handshake, X on sidebands | [openpcie_soc_sva.sv](../tb/sva/openpcie_soc_sva.sv) (bound) |
| Monitor | rules that need packet history: stability across a stall, `tkeep` by beat position | [openpcie_axis_monitor.svh](../tb/agents/axis_agent/openpcie_axis_monitor.svh) |
| Scoreboard | wrong TLP content, missing or extra packets, wrong register readback | [openpcie_scoreboard.svh](../tb/env/openpcie_scoreboard.svh) |
| End of test | items left in queues; no TX activity in a test that requires it | scoreboard `check_phase` |

A test that produces no traffic at all fails, rather than passing silently.

### 5.3 Pass/fail

`openpcie_base_test` prints `TEST PASSED` only when the report server counts no
`UVM_ERROR` and no `UVM_FATAL`. Both assertion modules report failures through
`uvm_report_error` (IDs `SVA/AXIS` and `SVA/SOC`) rather than `$error`, so an
assertion failure on its own also fails the test, on every simulator. Each
assertion instance reports its first 20 failures and then counts silently;
the total is printed at the end of simulation.

---

## 6. Coverage collection

| Source | What it samples |
|---|---|
| `openpcie_soc_coverage` (env) | register offset x direction from the CPU bus; TLP Type, Fmt, Length and final `tkeep` from expected packets; sideband values |
| `openpcie_axis_coverage` (per AXIS agent) | packet shape: beat count, final `tkeep`, byte count |
| `cover property` in both SVA files | stall patterns, back-to-back packets, FSM stalls in each state, RX phase toggle, credit exhaustion |

The Tier 1 coverage goal leaves out shapes the DUT cannot produce (4-DW
headers, multi-beat payloads). They are kept in zero-weight groups so Tier 2
gets the full model back by clearing the `tier1_shapes` knob. Details are in
[verification_plan.md, section 8](verification_plan.md#8-coverage-plan).

---

## 7. Build and run flow

```
rtl/openPCIE/.../src  ──rtl_patches.py──▶  build/rtl_patched/   (RTL + documented patches)
tb/fw/mailbox_fw.s    ──build_fw.py────▶  build/fw/firmware.hex (after the Python self-test)
sim/rtl.f + sim/tb.f  ──xvlog / xelab──▶  build/xsim/tb_top_snap
                      ──xsim───────────▶  build/xsim/<logdir>/<test>_<seed>.log + coverage database
                      ──xcrg───────────▶  build/xsim/<logdir>/cov_report/
```

`scripts/run.py` (xsim) and `sim/Makefile` (VCS, Xcelium) both regenerate the
patched RTL and the firmware before compiling. Everything under `build/` is
generated and is not under version control.

`--fixes` (or `make FIXES=1`) adds the two optional functional fixes to the
patched RTL and defines `OPENPCIE_RTL_FIXES`. Without it, the default run
measures the RTL as written.

---

## 8. Design decisions

**One AXIS agent class, three roles.** `axis_role_e` selects master, slave or
passive. The DUT sources `s_axis_tx_*` and sinks `m_axis_rx_*`, so the TB takes
the opposite role on each port. Both use the same monitor class, which keeps
the observed and expected packet formats identical.

**Backpressure profiles.** The slave role has four modes: `READY_ALWAYS`,
`READY_RANDOM` (with a percentage), `READY_SLOW` (one beat every N cycles) and
`READY_BURST` (accept/stall runs). The responder warns at the end of a test
if it was configured to stall but never did, since such a test proves nothing
about backpressure.

**RAL through the firmware.** No bus agent can reach the bridge registers, so
`openpcie_fw_frontdoor` sends every RAL access through the mailbox. The TX
registers are declared write-only because they read back 0; declaring them
read-write would make `uvm_reg_bit_bash_seq` fail on correct RTL.

**Status readbacks after settling.** `pcie_err_status_reg` and
`pcie_phy_status_reg` are registered one cycle behind their inputs
([riscv_pcie_soc.sv:147-155](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv#L147-L155)).
The predictor checks a readback strictly only after the sideband has been
stable, and masks `tx_state` out of the `PHY_STATUS` compare because it is
internal and transient.

**Upstream RTL is never edited.** The RTL is a pinned git submodule.
[scripts/rtl_patches.py](../scripts/rtl_patches.py) copies it to
`build/rtl_patched/` and applies the documented patches. If upstream changes
the code under a patch, the script stops and names the patch instead of
silently dropping it.

**xsim specifics.** Elaboration uses `--debug typical`; without it xsim's
optimiser breaks the `ref`-port aliasing in the RAM backdoor and every test
times out waiting for the firmware to boot. `tx_random` picks TLP kind and
Length in procedural code, because xsim 2026.1's solver never produced the
"memory read, no data" combination when Length was conditioned on Fmt/Type
inside a constraint.

---

## 9. Extending to Tier 2

`host_bridge` has the same AXI4-Stream ports plus `tuser`:

- `openpcie_axis_agent` works unchanged; `USER_W` is a parameter and the item
  already models `tuser`.
- `openpcie_tlp` handles 4-DW headers and multi-DW payloads; only the
  `c_tier1_shape` soft constraint needs to be relaxed.
- In `openpcie_soc_sva`, the sideband assertions (`SOC-010`) carry over; the
  FSM assertions do not apply.
- New work: a PIPE agent, an LTSSM tracker, and the Vivado `compile_simlib`
  libraries in the Makefile.
