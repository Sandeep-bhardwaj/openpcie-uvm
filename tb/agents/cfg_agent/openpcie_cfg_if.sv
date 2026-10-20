//---------------------------------------------------------------------------
// openPCIE UVM - configuration / status sideband interface
//---------------------------------------------------------------------------
// The `riscv_pcie_soc` sidebands that a real `host_bridge` would drive:
//
//   cfg_status[15:0]            PCIe device status register, readable by
//                               firmware at bridge offset 0x1C bits [15:0]
//   cfg_command[15:0]           PCIe command register.  NOTE: this port is
//                               declared on the DUT but is neither read
//                               internally nor connected at the chip top
//                               (RC_direct_opensource.sv:124-144).  The TB
//                               drives it anyway so the dangling-input defect
//                               is observable rather than silently X.
//   cfg_msg_received_err_fatal  latched into ERR_STATUS bit 16
//   tx_buf_av[5:0]              transmit buffer credit, readable in PHY_STATUS
//---------------------------------------------------------------------------

`ifndef OPENPCIE_CFG_IF_SV
`define OPENPCIE_CFG_IF_SV

interface openpcie_cfg_if (
  input logic clk,
  input logic rst_n
);

  logic [15:0] cfg_status;
  logic [15:0] cfg_command;
  logic        cfg_msg_received_err_fatal;
  logic [5:0]  tx_buf_av;

  // Sample-only, for the same reason as openpcie_axis_if: a clocking-block
  // `output` is a driver, and the agent also assigns these signals directly
  // at time 0 so the DUT never samples X before the first edge.  Two drivers
  // on one variable is what VCS reports as ICPSD_W / ICPD.  The driver
  // assigns the signals directly instead.
  clocking mon_cb @(posedge clk);
    default input #1step;
    input cfg_status, cfg_command, cfg_msg_received_err_fatal, tx_buf_av;
  endclocking

  modport mon (clocking mon_cb, input clk, rst_n);

endinterface

`endif // OPENPCIE_CFG_IF_SV
