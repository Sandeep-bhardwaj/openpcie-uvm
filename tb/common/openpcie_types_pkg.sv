//---------------------------------------------------------------------------
// openPCIE UVM - shared types, virtual-interface typedefs and DUT constants
//---------------------------------------------------------------------------
// Everything here is derived from the openPCIE RTL (rtl/openPCIE).  When a value
// mirrors a specific line of design source, the reference is given so a future
// RTL change can be traced back to the thing in the TB that assumed it.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_TYPES_PKG_SV
`define OPENPCIE_TYPES_PKG_SV

package openpcie_types_pkg;

  // ---- Tier 1 datapath geometry (riscv_pcie_soc.sv:46-56) --------------
  parameter int AXIS_DATA_W = 64;
  parameter int AXIS_KEEP_W = AXIS_DATA_W / 8;
  parameter int AXIS_USER_W = 4;

  typedef virtual openpcie_axis_if #(AXIS_DATA_W, AXIS_USER_W) axis_vif_t;
  typedef virtual openpcie_cfg_if                              cfg_vif_t;
  typedef virtual openpcie_cpu_if                              cpu_vif_t;
  typedef virtual openpcie_ram_bkdr_if                         ram_bkdr_vif_t;

  // ---- Bridge register map (riscv_pcie_soc.sv:176-254) -----------------
  // The decode uses only mem_addr[5] and mem_addr[4:2], so the whole
  // 0x30xxxxxx window aliases with a 64-byte period.  Stay inside 0x00-0x3F.
  parameter bit [31:0] BRIDGE_BASE     = 32'h3000_0000;

  parameter bit [31:0] REG_TX_HDR0     = 32'h0000_0000;  // W  TLP DW0
  parameter bit [31:0] REG_TX_HDR1     = 32'h0000_0004;  // W  TLP DW1
  parameter bit [31:0] REG_TX_HDR2     = 32'h0000_0008;  // W  TLP DW2
  parameter bit [31:0] REG_TX_DATA     = 32'h0000_000C;  // W  payload + trigger
  parameter bit [31:0] REG_RX_STATUS   = 32'h0000_0010;  // R  {29'b0, cpl_status}
  parameter bit [31:0] REG_RX_DATA     = 32'h0000_0014;  // R  captured payload DW
  parameter bit [31:0] REG_RX_HDR_INFO = 32'h0000_0018;  // R  captured DW2
  parameter bit [31:0] REG_ERR_STATUS  = 32'h0000_001C;  // R  {err_fatal, cfg_status}
  parameter bit [31:0] REG_PHY_STATUS  = 32'h0000_0020;  // R  {tx_state, tx_buf_av}

  // ---- SoC RAM (riscv_pcie_soc.sv:98) ----------------------------------
  parameter int unsigned RAM_WORDS = 2048;               // logic [31:0] ram[0:2047]

  // ---- Firmware mailbox - MUST match tb/fw/mailbox_fw.s -------------------
  parameter bit [31:0] MBOX_BASE  = 32'h0000_1F00;
  parameter bit [31:0] MBOX_CMD   = MBOX_BASE + 32'h00;
  parameter bit [31:0] MBOX_ARG0  = MBOX_BASE + 32'h04;
  parameter bit [31:0] MBOX_ARG1  = MBOX_BASE + 32'h08;
  parameter bit [31:0] MBOX_ARG2  = MBOX_BASE + 32'h0C;
  parameter bit [31:0] MBOX_ARG3  = MBOX_BASE + 32'h10;
  parameter bit [31:0] MBOX_RSP   = MBOX_BASE + 32'h14;
  parameter bit [31:0] MBOX_ACK   = MBOX_BASE + 32'h18;
  parameter bit [31:0] MBOX_ALIVE = MBOX_BASE + 32'h1C;

  parameter bit [31:0] MBOX_ALIVE_MAGIC = 32'h1E5D_0001;

  typedef enum bit [31:0] {
    FW_CMD_IDLE      = 32'd0,
    FW_CMD_SEND_TLP  = 32'd1,
    FW_CMD_READ_REG  = 32'd2,
    FW_CMD_WRITE_REG = 32'd3,
    FW_CMD_NOP       = 32'd4
  } fw_cmd_e;

  // ---- TX FSM encoding (riscv_pcie_soc.sv:136-141) ---------------------
  typedef enum bit [1:0] {
    TX_IDLE         = 2'd0,
    TX_SEND_CYCLE_1 = 2'd1,
    TX_SEND_CYCLE_2 = 2'd2
  } tx_state_e;

  // ---- Agent roles ------------------------------------------------------
  typedef enum {
    AXIS_ROLE_MASTER,     // TB sources beats  (used on the DUT's RX port)
    AXIS_ROLE_SLAVE,      // TB sinks beats and owns tready (DUT's TX port)
    AXIS_ROLE_MONITOR     // passive
  } axis_role_e;

  // Backpressure profiles for the slave role.  RANDOM is what exposes the
  // TX FSM's early-tready sampling; see docs/verification_plan.md, TX-PROTO-004.
  typedef enum {
    READY_ALWAYS,         // tready tied high - matches a permissive sink
    READY_RANDOM,         // Bernoulli per cycle, weighted by ready_pct
    READY_BURST,          // alternating accept/stall runs
    READY_SLOW            // one beat accepted every ready_period cycles
  } axis_ready_mode_e;

endpackage

`endif // OPENPCIE_TYPES_PKG_SV
