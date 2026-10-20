# riscv_pcie_soc - memory and register map

Reference for the DUT's CPU-visible address space, as implemented in
[riscv_pcie_soc.sv](https://github.com/chili-chips-ba/openPCIE/blob/6e48e11957e3f13494fbf6ffec91bfe2485d4e13/2.rtl/2.RC-direct.opensource/src/riscv_pcie_soc.sv)
at openPCIE commit `6e48e11`. Line numbers below refer to that file. The
testbench mirrors this map in `tb/common/openpcie_types_pkg.sv` and
`tb/ral/openpcie_ral.svh`; `scripts/check_tb.py` checks that the copies agree.

## CPU address space

The PicoRV32 native bus is decoded on address bits `[31:24]` (lines 80-81):

| Range | Target | Notes |
|---|---|---|
| `0x0000_0000` - `0x00FF_FFFF` | RAM, 2048 x 32 bit (8 KiB) | Indexed by `mem_addr[12:2]`, so the 8 KiB repeats through the range. Loaded at time 0 by `$readmemh("firmware.hex")` |
| `0x3000_0000` - `0x30FF_FFFF` | PCIe bridge registers | Decoded on `mem_addr[5]` and `mem_addr[4:2]` only, so the 64-byte block repeats through the range |
| anything else | - | Never completes: `mem_ready` (line 256) is driven only by the RAM and the bridge, so the CPU stalls. The read mux returns `0xDEADBEEF` |

CPU reset vector `0x0000_0000`; initial stack pointer `0x0000_2000`, one word
past the end of RAM (finding FW-001; the mailbox firmware uses no stack).

The testbench firmware keeps its command mailbox at `0x1F00`-`0x1F1F`; see
[tb_architecture.md, section 4.1](tb_architecture.md#41-firmware-mailbox).

## Bridge registers (base `0x3000_0000`)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x00` | `TX_HDR0` | WO | - | TLP header DW0 |
| `0x04` | `TX_HDR1` | WO | - | TLP header DW1 |
| `0x08` | `TX_HDR2` | WO | - | TLP header DW2 |
| `0x0C` | `TX_DATA` | WO | - | Payload DW. **Writing it starts the transmit** |
| `0x10` | `RX_STATUS` | RO | 0 | Completion status of the last captured completion |
| `0x14` | `RX_DATA` | RO | 0 | Upper DW of the second beat of the last captured completion |
| `0x18` | `RX_HDR_INFO` | RO | 0 | Lower DW of the second beat of the last captured completion |
| `0x1C` | `ERR_STATUS` | RO | 0 | Configuration status and fatal-error flag |
| `0x20` | `PHY_STATUS` | RO | 0 | Transmit state and transmit credits |

Write-only registers read back 0 (the default arm of the read decode). The
TX header registers are not reset.

### Field definitions

**`RX_STATUS`** (line 218)

| Bits | Field | Source |
|---|---|---|
| 31:3 | - | 0 |
| 2:0 | `cpl_status` | `m_axis_rx_tdata[47:45]` of the first beat (Completion Status: 0 SC, 1 UR, 2 CRS, 4 CA) |

**`RX_DATA`, `RX_HDR_INFO`** (lines 223-224): `m_axis_rx_tdata[63:32]` and
`m_axis_rx_tdata[31:0]` of every beat after the first, until `tlast`. For a
3-DW completion with one data DW, that is the payload and header DW2.

**`ERR_STATUS`** (line 152, registered one cycle after the inputs)

| Bits | Field | Source |
|---|---|---|
| 31:17 | - | 0 |
| 16 | `err_fatal` | `cfg_msg_received_err_fatal` |
| 15:0 | `cfg_status` | `cfg_status` |

**`PHY_STATUS`** (line 153, registered one cycle after the inputs)

| Bits | Field | Source |
|---|---|---|
| 31:8 | - | 0 |
| 7:6 | `tx_state` | 0 IDLE, 1 SEND_CYCLE_1, 2 SEND_CYCLE_2 |
| 5:0 | `tx_buf_av` | `tx_buf_av` |

## Decode details

**Reads** (lines 235-254). If `mem_addr[5]` is set, the read returns
`PHY_STATUS` whatever bits `[4:2]` are, so offsets `0x20`-`0x3C` all read
`PHY_STATUS`. Otherwise `mem_addr[4:2]` selects `0x10`-`0x1C`; offsets
`0x00`-`0x0C` read 0.

**Writes** (lines 176-187). Only `mem_addr[4:2]` is decoded; `mem_addr[5]` is
ignored. A write to `0x20` therefore lands in `TX_HDR0`, `0x24` in `TX_HDR1`,
`0x28` in `TX_HDR2`, and a write to `0x2C` starts a transmit (finding
REG-004). Writes to `0x10`-`0x1C` and `0x30`-`0x3C` have no effect.

**Both directions** repeat every 64 bytes through `0x30xx_xxxx` (finding
REG-003). Any register added later must fit in offsets `0x00`-`0x3F` or the
decode must be widened.

## Transmit behaviour

Writing `TX_DATA` sets the transmit state to `SEND_CYCLE_1` (line 182). The
state machine then sends two beats on `s_axis_tx_*`:

| Beat | `tdata[63:32]` | `tdata[31:0]` | `tkeep` | `tlast` |
|---|---|---|---|---|
| 0 | `TX_HDR1` | `TX_HDR0` | `0xFF` | 0 |
| 1 | `TX_DATA` | `TX_HDR2` | `0xFF` if `TX_HDR0[30]` (Fmt: with data), else `0x0F` | 1 |

The header registers keep their values, so a second packet with the same
header needs only a new `TX_DATA` write. There is no busy interlock. A
`TX_DATA` write while a packet is in flight is not queued: the state machine's
own transition is assigned later in the same block and wins, so the new
packet can be dropped, and because `TX_DATA` and the header registers are
overwritten at once, the packet in flight can go out with the new values
(TX-FLOW-002). Software must poll `PHY_STATUS[7:6]` for IDLE before each send. As written, the state machine
also checks `tready` one cycle too early and loses beat 0 under backpressure
(TX-PROTO-004); see [verification_plan.md, section 11](verification_plan.md#11-design-findings).

## Receive behaviour

`m_axis_rx_tready` is tied high (line 233); the DUT never stalls inbound
traffic. On a beat with `tvalid`:

- in phase 0, if `tdata[28:24]` is `01010` (Type = Completion), `RX_STATUS` is
  captured and the state moves to phase 1; any other beat is ignored;
- in phase 1, `RX_DATA` and `RX_HDR_INFO` are captured from every beat, and
  the state returns to phase 0 on `tlast`.

`tkeep` is not examined, and there is no check that a phase-0 beat is the
first beat of a packet (finding RX-CAP-003).
