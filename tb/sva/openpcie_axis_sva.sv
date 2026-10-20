//---------------------------------------------------------------------------
// openpcie_axis_sva - cycle-local AXI4-Stream protocol checks
//---------------------------------------------------------------------------
// Rules from AMBA AXI4-Stream Protocol Specification (IHI 0051), section 2.2.1
// and Table 2-2.  Only properties expressible in a bounded window live here;
// anything needing packet history is checked in the UVM monitor instead.
//
// Instantiated (not bound) from tb_top so the connection is explicit and
// portable across VCS and Xcelium.  `ROLE_IS_DUT_SOURCE` selects which side of
// the interface the DUT is on, because the source-side obligations only apply
// to whichever agent is driving.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_SVA_SV
`define OPENPCIE_AXIS_SVA_SV

module openpcie_axis_sva #(
  parameter int    DATA_W = 64,
  parameter int    USER_W = 4,
  parameter string IF_NAME = "axis",
  // 1 when the DUT sources this stream (s_axis_tx_*), 0 when the TB does.
  parameter bit    DUT_IS_SOURCE = 1,
  parameter bit    ENABLE = 1,
  // A systemic failure fires every cycle; without a cap one broken property
  // buries the log and hides everything else.  Report the first MAX_FAILS,
  // then count silently and print the total at end of test.
  parameter int    MAX_FAILS = 20
) (
  input logic                clk,
  input logic                rst_n,
  input logic [DATA_W-1:0]   tdata,
  input logic [DATA_W/8-1:0] tkeep,
  input logic [USER_W-1:0]   tuser,
  input logic                tlast,
  input logic                tvalid,
  input logic                tready
);

  localparam int KEEP_W = DATA_W / 8;

  // A packed stream's tkeep is a contiguous run of ones from bit 0.
  function automatic bit keep_packed(logic [KEEP_W-1:0] k);
    bit seen_zero = 1'b0;
    for (int i = 0; i < KEEP_W; i++) begin
      if (!k[i])      seen_zero = 1'b1;
      else if (seen_zero) return 1'b0;
    end
    return 1'b1;
  endfunction

  default clocking cb @(posedge clk); endclocking
  // Reset qualification is written on each directive: xsim does not support
  // `default disable iff` (XSIM 43-3980).

  // ---- bounded failure reporting --------------------------------------
  int unsigned n_fail;

  // Failures go through the UVM report server rather than $error, so they
  // count as UVM_ERRORs and fail the test on every simulator.
  function automatic void note_fail(string msg);
    n_fail++;
    if (n_fail <= MAX_FAILS)
      uvm_pkg::uvm_report_error("SVA/AXIS", msg, uvm_pkg::UVM_NONE);
    else if (n_fail == MAX_FAILS + 1)
      $display("[%s] %0d assertion failures reported; suppressing the rest.",
               IF_NAME, MAX_FAILS);
  endfunction

  final begin
    if (n_fail > MAX_FAILS)
      $display("[%s] TOTAL assertion failures: %0d (%0d suppressed)",
               IF_NAME, n_fail, n_fail - MAX_FAILS);
  end

  //-----------------------------------------------------------------------
  // Source obligations
  //-----------------------------------------------------------------------

  // AXIS-001: once asserted, tvalid must stay asserted until tready.
  property p_tvalid_held;
    tvalid && !tready |=> tvalid;
  endproperty

  // AXIS-002: the payload must not change while a beat is stalled.  This is
  // the property that catches riscv_pcie_soc.sv:195-211 - the transmit FSM
  // advances state one cycle before its beat is presented, so under
  // backpressure beat 0 is overwritten by beat 1 before it was accepted.
  property p_payload_stable;
    tvalid && !tready |=> $stable(tdata) && $stable(tkeep)
                       && $stable(tlast) && $stable(tuser);
  endproperty

  // AXIS-003: a beat with tvalid must carry at least one valid byte.
  property p_no_null_beat;
    tvalid |-> (tkeep != '0);
  endproperty

  // AXIS-004: tkeep must be a contiguous run from bit 0.
  property p_keep_packed;
    tvalid |-> keep_packed(tkeep);
  endproperty

  // AXIS-005: only the final beat of a packet may be partial.
  property p_partial_only_on_last;
    (tvalid && (tkeep != '1)) |-> tlast;
  endproperty

  // AXIS-006: no X or Z on control while tvalid is asserted.  Cheap, and it is
  // what surfaces the dangling cfg_command input at the chip top rather than
  // letting X propagate silently.
  property p_no_x_on_control;
    tvalid |-> (!$isunknown({tkeep, tlast}));
  endproperty

  property p_no_x_on_data;
    (tvalid && tready) |-> (!$isunknown(tdata));
  endproperty

  //-----------------------------------------------------------------------
  // Handshake obligations (both sides)
  //-----------------------------------------------------------------------

  // AXIS-007: tvalid and tready must never be X once out of reset.
  property p_handshake_defined;
    !$isunknown(tvalid) && !$isunknown(tready);
  endproperty

  //-----------------------------------------------------------------------
  // Assertions
  //-----------------------------------------------------------------------
  generate
  if (ENABLE) begin : g_sva

    a_tvalid_held : assert property (disable iff (!rst_n) p_tvalid_held)
      else note_fail($sformatf("[%s] AXIS-001: tvalid deasserted before tready was seen",
                  IF_NAME));

    a_payload_stable : assert property (disable iff (!rst_n) p_payload_stable)
      else note_fail($sformatf({"[%s] AXIS-002: payload changed during a stall - tdata/tkeep/",
                   "tlast must hold until tready. (was %0h/%0h/%0b)"},
                  IF_NAME, $past(tdata), $past(tkeep), $past(tlast)));

    a_no_null_beat : assert property (disable iff (!rst_n) p_no_null_beat)
      else note_fail($sformatf("[%s] AXIS-003: tvalid with tkeep==0", IF_NAME));

    a_keep_packed : assert property (disable iff (!rst_n) p_keep_packed)
      else note_fail($sformatf("[%s] AXIS-004: tkeep=%0h is not a contiguous run from bit 0",
                  IF_NAME, tkeep));

    a_partial_only_on_last : assert property (disable iff (!rst_n) p_partial_only_on_last)
      else note_fail($sformatf("[%s] AXIS-005: partial tkeep=%0h on a non-final beat",
                  IF_NAME, tkeep));

    a_no_x_on_control : assert property (disable iff (!rst_n) p_no_x_on_control)
      else note_fail($sformatf("[%s] AXIS-006: X/Z on tkeep or tlast while tvalid asserted",
                  IF_NAME));

    a_no_x_on_data : assert property (disable iff (!rst_n) p_no_x_on_data)
      else note_fail($sformatf("[%s] AXIS-006: X/Z on tdata during an accepted beat",
                  IF_NAME));

    a_handshake_defined : assert property (disable iff (!rst_n) p_handshake_defined)
      else note_fail($sformatf("[%s] AXIS-007: tvalid or tready is X/Z out of reset",
                  IF_NAME));

    //---------------------------------------------------------------------
    // Cover - proves the stimulus actually reached the interesting states.
    // A backpressure test whose covers are empty verified nothing.
    //---------------------------------------------------------------------
    c_stall           : cover property (disable iff (!rst_n) tvalid && !tready);
    c_stall_2cyc      : cover property (disable iff (!rst_n) tvalid && !tready [*2]);
    c_stall_5cyc      : cover property (disable iff (!rst_n) tvalid && !tready [*5]);
    c_stall_on_first  : cover property (disable iff (!rst_n) tvalid && !tready && !tlast);
    c_stall_on_last   : cover property (disable iff (!rst_n) tvalid && !tready &&  tlast);
    c_btb_packets     : cover property (disable iff (!rst_n) (tvalid && tready && tlast)
                                        ##1 (tvalid && tready));
    c_partial_last    : cover property (disable iff (!rst_n) tvalid && tready && tlast
                                        && (tkeep == 8'h0F));
    c_full_last       : cover property (disable iff (!rst_n) tvalid && tready && tlast
                                        && (tkeep == '1));

  end
  endgenerate

`ifdef OPENPCIE_SVA_VERBOSE
  initial $display("[%0t] openpcie_axis_sva instantiated for '%s' (DUT is %s)",
                   $time, IF_NAME, DUT_IS_SOURCE ? "source" : "sink");
`endif

endmodule

`endif // OPENPCIE_AXIS_SVA_SV
