# openpcie-uvm

A UVM verification environment for the open-source **PCIe Gen2 Root Complex** of the
[openPCIE](https://github.com/chili-chips-ba/openPCIE) project (Xilinx Artix-7), running on
**AMD Vivado xsim**, with VCS and Xcelium supported through a Makefile.

The design under test is `riscv_pcie_soc`: a PicoRV32 RISC-V CPU, its 8 KiB RAM, and the bridge
that turns CPU register writes into TLPs on a 64-bit AXI4-Stream port and captures inbound
completions. It is the open-source logic of the Root Complex; the PCIe hard block and the
transceivers around it are Xilinx IP and belong to later tiers.

> Status: Tier 1 complete on xsim. 11 tests x 5 seeds pass with the proposed RTL fixes, functional
> coverage 100 % of the Tier 1 goal. Three RTL issues were found and confirmed in simulation; the
> fixes are in [patches/](patches/). Verification plan:
> [docs/verification_plan.md](docs/verification_plan.md), testplan: [docs/testplan.md](docs/testplan.md).

## Contents

- [What is verified](#what-is-verified)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Running tests](#running-tests)
- [Regressions and coverage](#regressions-and-coverage)
- [VCS and Xcelium](#vcs-and-xcelium)
- [Static checks](#static-checks)
- [How the testbench works](#how-the-testbench-works)
- [Tests](#tests)
- [Results](#results)
- [Findings](#findings)
- [Patches for openPCIE](#patches-for-openpcie)
- [Known limitations](#known-limitations)
- [Documentation](#documentation)
- [License](#license)

## What is verified

| Area | Checked by |
|---|---|
| TX framing: 3-DW header + payload in two 64-bit beats, `tkeep`/`tlast` | reference model + scoreboard, white-box assertions |
| TX handshake under backpressure (always ready, random, slow, bursty sink) | AXI4-Stream assertions, monitor, scoreboard |
| All Tier 1 TLP kinds (MEM, IO, CFG0, CFG1, CPL) and Lengths 1-1024 | constrained-random test + scoreboard |
| RX completion capture (status, data, header) and rejection of other TLPs | register readback vs model |
| Bridge register map: read decode, write-only registers, aliasing, writes to read-only registers | RAL through the CPU, scoreboard |
| Sideband reflection (`cfg_status`, fatal error, transmit credits), including zero credits | readback vs model |
| Reset in the middle of traffic, CPU re-boot, recovery | directed checks |
| PicoRV32 bus handshake as seen by the bridge | white-box assertions |

The full requirement list (29 items, each traced to a check, a coverage item and a test) is in
[docs/verification_plan.md](docs/verification_plan.md#6-feature-list-and-verification-requirements).

## Repository layout

```
rtl/openPCIE/        git submodule: github.com/chili-chips-ba/openPCIE @ 6e48e11, unmodified
patches/             the RTL fixes found here, as git patches against openPCIE
scripts/
  run.py             compile / test / regress / coverage on xsim
  rtl_patches.py     copy the RTL to build/rtl_patched/ and apply the documented patches
  check_tb.py        static consistency checks (no simulator needed)
  slang_check.py     parse + elaborate with slang (no simulator needed)
  tx_fsm_model.py    cycle model of the TX state machine, original vs fixed
  make_upstream_patches.py  regenerate patches/ from rtl_patches.py
  gen_testplan_xlsx.py      regenerate docs/testplan.xlsx
sim/
  rtl.f, tb.f        design and testbench filelists
  Makefile           VCS / Xcelium flow
tb/
  agents/axis_agent/ AXI4-Stream agent: master, slave with backpressure profiles, passive
  agents/cfg_agent/  sideband agent
  agents/cpu_agent/  passive PicoRV32 bus monitor (interface bound into the DUT)
  common/            types, register and mailbox constants, TLP model
  ral/               register model + firmware frontdoor
  env/               env, config, firmware mailbox, predictor, scoreboard, coverage
  seq/               virtual sequences
  tests/             test library
  sva/               AXI4-Stream and white-box assertions
  top/               tb_top, binds, reset and RAM-backdoor interfaces
  fw/                PicoRV32 mailbox firmware, RV32I assembler/ISS, self-test
docs/                verification plan, testplan (+ .xlsx), architecture, register map, results
```

Everything the scripts generate (patched RTL, firmware image, simulator databases, logs,
coverage reports) goes to `build/`, which is not under version control.

## Requirements

* Vivado 2023.1 or later (developed on 2026.1) - xsim with its bundled UVM 1.2. No Xilinx
  simulation libraries are needed: nothing in this DUT instantiates a vendor primitive.
* Python 3.9 or later (developed on 3.12). `openpyxl` only to regenerate the testplan workbook, `pyslang` only for
  `slang_check.py`.
* Optional: Synopsys VCS or Cadence Xcelium with UVM 1.2, and GNU make.

No RISC-V toolchain is needed. The firmware is assembled by a small Python assembler in `tb/fw/`.

## Quick start

```bash
git clone --recursive https://github.com/Sandeep-bhardwaj/openpcie-uvm.git
cd openpcie-uvm

# compile and run the smoke test (about 1-2 minutes)
python scripts/run.py

# full regression on the RTL as written (4 of 11 tests fail on a real RTL bug - expected)
python scripts/run.py --regress --seeds 5 --logdir regress_nofix

# the same with the proposed RTL fixes, plus a merged coverage report
python scripts/run.py --fixes --regress --seeds 5 --logdir regress_fixed --cov-report
```

If the repository was cloned without `--recursive`, fetch the RTL with
`git submodule update --init`.

`run.py` finds Vivado on `PATH` or in the usual install locations (`C:/Xilinx/Vivado/*`,
`D:/AMDDesignTools/*/Vivado`); otherwise set `VIVADO_BIN` to Vivado's `bin` directory.

On Windows, a checkout with `core.autocrlf=true` gives the submodule CRLF line endings. That is
handled: `rtl_patches.py` normalises line endings when it copies the RTL.

## Running tests

```bash
python scripts/run.py -t openpcie_tx_backpressure_test -s 7      # one test, one seed
python scripts/run.py --no-compile -t openpcie_random_test -s 3   # reuse the last compile
python scripts/run.py --fixes -t openpcie_tx_backpressure_test    # with the RTL fixes
python scripts/run.py -t openpcie_smoke_test --verb UVM_HIGH       # more detail in the log
```

Each run prepares its inputs first: it assembles the firmware and runs its self-test
(`build/fw/firmware.hex`), and copies the RTL into `build/rtl_patched/` with the documented
patches. It then compiles once into `build/xsim/` and writes one log per test and seed to
`build/xsim/<logdir>/<test>_<seed>.log`. A test passes when the log ends with `TEST PASSED`,
which requires zero `UVM_ERROR` and zero `UVM_FATAL`; assertion failures are reported as
`UVM_ERROR` too.

| Option | Effect |
|---|---|
| `-t NAME` | test to run (default `openpcie_smoke_test`) |
| `-s N` | seed (default 1) |
| `--regress` | run all 11 tests |
| `--seeds N` | with `--regress`: seeds 1..N for every test |
| `--fixes` | apply the optional RTL fixes (TX-PROTO-004, REG-004) and tell the predictor |
| `--no-compile` | reuse the last snapshot |
| `--logdir NAME` | log directory under `build/xsim/` (default `logs`) |
| `--verb LEVEL` | UVM verbosity (default `UVM_MEDIUM`) |
| `-D NAME[=VALUE]` | extra compile define, e.g. `-D OPENPCIE_SOC_SVA_ENABLE=0` to drop the white-box assertions |
| `--cov-report` | merge the coverage databases in `--logdir` and write a report |
| `--report-only` | with `--cov-report`: only build the report |

`--fixes` changes the compiled RTL, so do not combine it with `--no-compile` after a build
without it (or the other way round).

## Regressions and coverage

The two runs in the quick start are the full regression. The first measures the RTL exactly as
upstream wrote it; the second applies the fixes from [patches/](patches/) and should pass
completely.

`--cov-report` merges every run's functional coverage database with `xcrg` and writes
`build/xsim/<logdir>/cov_report/functionalCoverageReport/dashboard.html`. Read the HTML report:
xcrg 2026.1 on Windows stops part-way through the text report, which then lists only the first
covergroup. xsim does not collect `cover property` results, so the assertion cover points need
VCS or Xcelium.

The coverage model and its exclusions are described in
[docs/verification_plan.md, section 8](docs/verification_plan.md#8-coverage-plan).

## VCS and Xcelium

```bash
cd sim
make                                  # smoke test on VCS
make SIM=xcelium TEST=openpcie_random_test SEED=7
make regress SEEDS=20 COV=1           # nightly: all tests, 20 seeds, code + functional coverage
make cov-report
make FIXES=1 regress                  # with the RTL fixes
make list                             # list the tests
make lint                             # static checks
```

Runs go to `build/run/<test>_<seed>/`, coverage to `build/cov/`. The Makefile has not been run
against a licensed VCS or Xcelium installation yet; the testbench uses no xsim-specific
constructs, and the same sources pass `slang_check.py`.

## Static checks

These need no simulator and run in CI on every push
([.github/workflows/ci.yml](.github/workflows/ci.yml)):

```bash
python tb/fw/build_fw.py                       # assemble the firmware, 24-check self-test
python scripts/rtl_patches.py                  # patch layer still applies to the RTL
python scripts/check_tb.py                     # 233 cross-file consistency checks
python scripts/tx_fsm_model.py -n 500 --seeds 2  # TX FSM model, original vs fixed
python scripts/make_upstream_patches.py --check
python scripts/slang_check.py                  # needs pyslang; set UVM_HOME for the tb tier
```

`check_tb.py` checks, among other things, that the filelists resolve, that `tb_top` connects
every DUT port, and that the register map, mailbox layout and RAM size agree between the RTL,
the firmware, the types package and the register model.

## How the testbench works

The bridge registers can only be reached by the CPU, so the environment runs a 43-instruction
firmware on the PicoRV32. The firmware waits for commands (send TLP, read register, write
register, barrier) in a mailbox in RAM. The testbench writes the mailbox through an interface
bound onto the DUT's RAM array, and the CPU performs the real bus accesses.

```
 test ─▶ virtual sequence ─┬─▶ firmware mailbox ──(RAM backdoor)──▶ PicoRV32 ─▶ bridge registers
                           ├─▶ RX agent (master)  ─▶ m_axis_rx_*
                           └─▶ sideband agent     ─▶ cfg_status, err_fatal, tx_buf_av

 s_axis_tx_* ─▶ TX agent (slave, drives tready) ─▶ scoreboard ◀─ predictor ◀─ CPU bus monitor (bound)
```

The predictor builds the expected packets from the register writes it sees on the CPU bus, not
from what the sequence intended, so a firmware or mailbox bug shows up as a mismatch. Two
assertion modules check the AXI4-Stream protocol on both ports and the DUT's internal state
machines. Details: [docs/tb_architecture.md](docs/tb_architecture.md).

## Tests

| Test | Description |
|---|---|
| `openpcie_smoke_test` | boot, one TLP out, status registers read back |
| `openpcie_tx_directed_test` | both final-beat `tkeep` values, boundary addresses, walking-ones payload |
| `openpcie_tx_random_test` | 20-400 random TLPs of every Tier 1 kind, always-ready sink |
| `openpcie_tx_backpressure_test` | TX under a sink that is ready 40 % of cycles |
| `openpcie_tx_slow_sink_test` | TX with one beat accepted every 4 cycles |
| `openpcie_tx_burst_sink_test` | TX with alternating 1-cycle accept / 3-cycle stall |
| `openpcie_rx_cpl_test` | completions with every status, with and without data; a non-completion TLP |
| `openpcie_reg_access_test` | register map through the RAL: read decode, write-only registers, writes to read-only registers, aliasing |
| `openpcie_sideband_test` | credits stepped down to zero, `cfg_status` extremes, fatal error at low credit |
| `openpcie_reset_test` | reset in the middle of traffic, re-boot, traffic again |
| `openpcie_random_test` | mixed TX, RX, register and sideband traffic under random backpressure |

Each test is specified (configuration, stimulus, checks, expected result) in
[docs/testplan.md](docs/testplan.md#5-test-case-specifications).

## Results

Vivado 2026.1 xsim, seeds 1-5 for every test, 2026-10-20. Per-test detail:
[docs/results.md](docs/results.md).

| RTL | Runs | Passed |
|---|---|---|
| As written (openPCIE `6e48e11`) | 55 | 35 - the 4 tests with a stalling sink fail on every seed (TX-PROTO-004) |
| With the fixes in [patches/](patches/) | 55 | **55**, 0 warnings |

| Coverage (fixed RTL, 55 runs merged) | |
|---|---|
| Functional coverage, Tier 1 goal | **100 %** |
| Register access / transmitted TLP / sidebands / packet shape | 100 % each |
| Diagnostic group of non-conforming TLPs (must stay empty) | 0 % |

Every error in the 20 failing runs comes from the TX handshake bug; there are no other errors.
Sign-off criteria and what is still open (assertion cover points and code coverage on
VCS/Xcelium, 20+ seeds) are in
[docs/verification_plan.md, section 10](docs/verification_plan.md#10-sign-off-criteria-and-current-status).

## Findings

Recorded with evidence in [docs/verification_plan.md, section 11](docs/verification_plan.md#11-design-findings):

* **TX-PROTO-004 - the TX state machine checks `tready` one cycle early.** `tvalid` and `tdata`
  are registered, but the transition tests `tready` in the cycle that schedules them. With an
  always-ready sink the two errors cancel. When the sink stalls, beat 1 overwrites beat 0 before it
  is accepted and the TLP header never reaches the link. The four stalling-sink tests fail on every
  seed; the always-ready tests pass.
* **REG-004 - register writes ignore address bit 5.** A write to the read-only `PHY_STATUS`
  (`+0x20`) overwrites `TX_HDR0`, and a write to `+0x2C` starts a transmit. Proven by
  `openpcie_reg_access_test`: the packet that follows carries the header written through `+0x20`.
* **RTL-SIM-001 - `ram` is written by both `$readmemh` and an `always_ff`.** IEEE 1800-2017
  9.2.2.4 does not allow this, and VCS refuses to elaborate the design. Changing the block to
  `always` has no behavioural effect.
* Documented behaviour, not bugs: the `cfg_command` input is unused, the register decode repeats
  every 64 bytes, the RX capture cannot resynchronise to packet boundaries, there is no TX busy
  interlock (software must poll), and the initial stack pointer is one word past the RAM.

## Patches for openPCIE

[patches/](patches/) holds one patch per fix plus `all-fixes.patch`. They are made against
openPCIE commit `6e48e11` and apply from the root of an openPCIE checkout:

```bash
cd rtl/openPCIE            # or any openPCIE checkout at 6e48e11
git apply ../../patches/all-fixes.patch
```

`scripts/make_upstream_patches.py` regenerates them from `scripts/rtl_patches.py` and refuses
to write a patch whose code differs from what was simulated. Upstream has since moved
`riscv_pcie_soc.sv` to `2.rtl/0.common.opensource/` and rewritten it, so the patches do not apply
to the current upstream head; the findings should be re-checked there.

## Known limitations

* Tier 1 only. The PCIe hard block, the GTP transceivers, link training and the full chip top are
  not simulated; they need the Xilinx simulation libraries (Tier 2 and 3, see the verification
  plan).
* The bridge emits exactly two beats per packet, so multi-DW payloads, 4-DW headers, ECRC and
  poisoned TLPs cannot be exercised at this tier.
* Assertion cover points and code coverage have not been collected yet: xsim ignores
  `cover property`, and no VCS or Xcelium run has been made.
* Regressions so far use 5 seeds per test; the sign-off target is 20 or more.
* The mailbox firmware does not poll for the transmitter to go idle before a send. That is safe
  for every sink profile used here, because a mailbox round trip takes longer than the slowest
  sink needs to drain a packet; a test with very long stalls would need it.

## Documentation

| Document | Content |
|---|---|
| [docs/verification_plan.md](docs/verification_plan.md) | scope, strategy, requirements, checks, coverage plan, regression, sign-off, findings, risks |
| [docs/testplan.md](docs/testplan.md) | test case specifications, traceability matrix, regression lists |
| [docs/testplan.xlsx](docs/testplan.xlsx) | tracking workbook: requirements, tests, traceability, coverage, checkers, findings, regression |
| [docs/tb_architecture.md](docs/tb_architecture.md) | testbench structure, stimulus paths, checking, build flow, design decisions |
| [docs/register_map.md](docs/register_map.md) | DUT address map, register fields, decode details |
| [docs/results.md](docs/results.md) | regression and coverage results per test |

## License

| Material | License |
|---|---|
| Testbench, firmware, scripts and documentation of this repository | MIT ([LICENSE](LICENSE)) |
| `patches/` - modify openPCIE's `riscv_pcie_soc.sv` | BSD 3-Clause, as the file they modify ([LICENSE.openPCIE](LICENSE.openPCIE)) |
| `rtl/openPCIE` (submodule, not included) | BSD 3-Clause, Copyright (c) 2026 Chili.CHIPS*ba; `picorv32.v` inside it is ISC |

No openPCIE source is committed apart from the context lines of the patches; the RTL is fetched as
a submodule and copied under `build/` by the scripts. Details and attributions: [NOTICE](NOTICE).

This project is not affiliated with or endorsed by Chili.CHIPS*ba or NLnet.
