//---------------------------------------------------------------------------
// openPCIE UVM - AXI4-Stream interface
//---------------------------------------------------------------------------
// Carries the Xilinx 7-Series PCIe flavour of AXI4-Stream used between
// `riscv_pcie_soc` and `host_bridge`.  `tuser` is protocol payload here, not a
// spare field:
//
//   TX (s_axis_tx_tuser[3:0])  = {src_dsc, streaming, err_fwd, ecrc_gen}
//                                 -- see stream_tx_path.sv:125-128
//   RX (m_axis_rx_tuser[21:0]) = {is_eof[4:0], is_sof[4:0], bar_hit[7:0], ...}
//                                 -- see stream_rx_path.sv:189-209
//
// Tier 1 (`riscv_pcie_soc`) exposes no tuser, so the interface's tuser is left
// unconnected there and USER_W defaults small.  The same interface and agent
// serve Tier 2, where `host_bridge` does drive it.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_IF_SV
`define OPENPCIE_AXIS_IF_SV

interface openpcie_axis_if #(
  parameter int DATA_W = 64,
  parameter int USER_W = 4
) (
  input logic clk,
  input logic rst_n
);

  localparam int KEEP_W = DATA_W / 8;

  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tkeep;
  logic [USER_W-1:0] tuser;
  logic              tlast;
  logic              tvalid;
  logic              tready;

  // ---------------------------------------------------------------------
  // ONE clocking block, and it is sample-only.
  //
  // A clocking block `output` elaborates to a continuous driver on the signal
  // (VCS renders it literally as `output tvalid = tvalid`).  This interface
  // type is instantiated on both sides of the DUT, so a master-side clocking
  // block would put a TB driver on tvalid/tdata/... of the *transmit* link,
  // where the DUT already drives them structurally, and a slave-side one would
  // do the same to tready on the *receive* link.  VCS reports that as
  //   Warning-[ICPSD_W] Illegal combination of structural and procedural drivers
  // and says it will become an error in a future release.
  //
  // So: monitors sample through `mon_cb`, and drivers assign the signals
  // directly with non-blocking assignments at the clock edge.  NBA ordering
  // still gives correct handshake semantics - the DUT's always_ff sees the
  // previous value at the same edge, exactly as a clocking block would.
  // ---------------------------------------------------------------------
  clocking mon_cb @(posedge clk);
    default input #1step;
    input tdata, tkeep, tuser, tlast, tvalid, tready;
  endclocking

  modport mon (clocking mon_cb, input clk, rst_n);

  // ---------------------------------------------------------------------
  // Convenience functions used by the monitor and by SVA.
  // ---------------------------------------------------------------------

  // A legal AXI4-Stream tkeep for a packed stream is a contiguous run of 1s
  // starting at bit 0 (only the final beat may be partial).
  function automatic bit keep_is_packed(logic [KEEP_W-1:0] k);
    bit seen_zero = 1'b0;
    for (int i = 0; i < KEEP_W; i++) begin
      if (!k[i]) seen_zero = 1'b1;
      else if (seen_zero) return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic int unsigned keep_bytes(logic [KEEP_W-1:0] k);
    int unsigned n = 0;
    for (int i = 0; i < KEEP_W; i++) n += k[i];
    return n;
  endfunction

endinterface

`endif // OPENPCIE_AXIS_IF_SV
