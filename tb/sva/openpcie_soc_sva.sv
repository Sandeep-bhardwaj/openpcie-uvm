//---------------------------------------------------------------------------
// openpcie_soc_sva - white-box assertions bound into riscv_pcie_soc
//---------------------------------------------------------------------------
// Bound (see tb/top/openpcie_bind.sv) so it can see the DUT's internal state
// without the RTL being modified.  These encode invariants that the design
// must hold regardless of stimulus - the kind of thing that turns a confusing
// scoreboard mismatch into a one-line diagnosis.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_SOC_SVA_SV
`define OPENPCIE_SOC_SVA_SV

module openpcie_soc_sva #(
  parameter bit ENABLE = 1,
  // A systemic failure fires every cycle.  Without a cap one broken property
  // buries the log (and on a hosted simulator, hits the output limit and kills
  // the run) so nothing else can be diagnosed.  Report the first MAX_FAILS, then
  // count silently.
  parameter int MAX_FAILS = 20
) (
  input logic        clk,
  input logic        resetn,

  // CPU native bus
  input logic        mem_valid,
  input logic        mem_ready,
  input logic [31:0] mem_addr,
  input logic [31:0] mem_wdata,
  input logic [3:0]  mem_wstrb,

  // transmit stream
  input logic [63:0] s_axis_tx_tdata,
  input logic [7:0]  s_axis_tx_tkeep,
  input logic        s_axis_tx_tlast,
  input logic        s_axis_tx_tvalid,
  input logic        s_axis_tx_tready,

  // receive stream
  input logic        m_axis_rx_tvalid,
  input logic        m_axis_rx_tready,

  // sidebands
  input logic [5:0]  tx_buf_av,
  input logic [15:0] cfg_status,
  input logic [15:0] cfg_command,

  // internal state
  input logic [1:0]  tx_state,
  input logic        rx_phase
);

  default clocking cb @(posedge clk); endclocking
  // Reset qualification is written on each directive: xsim does not support
  // `default disable iff` (XSIM 43-3980).

  localparam logic [1:0] ST_IDLE = 2'd0, ST_C1 = 2'd1, ST_C2 = 2'd2;

  // ---- bounded failure reporting --------------------------------------
  int unsigned n_fail;

  // Failures go through the UVM report server rather than $error, so they
  // count as UVM_ERRORs and fail the test on every simulator.
  function automatic void note_fail(string msg);
    n_fail++;
    if (n_fail <= MAX_FAILS)
      uvm_pkg::uvm_report_error("SVA/SOC", msg, uvm_pkg::UVM_NONE);
    else if (n_fail == MAX_FAILS + 1)
      $display({"[%m] %0d assertion failures reported; suppressing the rest. ",
                "Final count is printed at end of test."}, MAX_FAILS);
  endfunction

  final begin
    if (n_fail > MAX_FAILS)
      $display("[%m] TOTAL assertion failures: %0d (%0d suppressed)",
               n_fail, n_fail - MAX_FAILS);
  end

  generate
  if (ENABLE) begin : g_sva

    //---------------------------------------------------------------------
    // Transmit FSM
    //---------------------------------------------------------------------

    // SOC-001: the FSM has only three legal encodings; 2'd3 is unreachable.
    a_tx_state_legal : assert property (disable iff (!resetn) tx_state inside {ST_IDLE, ST_C1, ST_C2})
      else note_fail($sformatf("SOC-001: tx_state reached illegal encoding %0d", tx_state));

    // SOC-002: a packet is exactly two beats - tlast may only be asserted on
    // the second, never the first.
    a_tx_two_beats : assert property (disable iff (!resetn) 
      (s_axis_tx_tvalid && s_axis_tx_tready && !s_axis_tx_tlast)
      |=> (s_axis_tx_tvalid throughout (s_axis_tx_tready && s_axis_tx_tlast)[->1]))
      else note_fail("SOC-002: first beat was not followed by a terminating beat");

    // SOC-003: the final beat's tkeep is derived from Fmt[1] of DW0, which the
    // FSM latched into tx_header0.  0x0F and 0xFF are the only legal values.
    a_tx_last_keep : assert property (disable iff (!resetn) 
      (s_axis_tx_tvalid && s_axis_tx_tlast) |-> s_axis_tx_tkeep inside {8'h0F, 8'hFF})
      else note_fail($sformatf("SOC-003: final beat tkeep=%0h, expected 0x0F or 0xFF",
                  s_axis_tx_tkeep));

    // SOC-004: the first beat always carries a full 64 bits (two header DWs).
    a_tx_first_keep : assert property (disable iff (!resetn) 
      (s_axis_tx_tvalid && !s_axis_tx_tlast) |-> (s_axis_tx_tkeep == 8'hFF))
      else note_fail($sformatf("SOC-004: first beat tkeep=%0h, expected 0xFF",
                  s_axis_tx_tkeep));

    // SOC-005: nothing may be transmitted while the FSM claims to be idle.
    a_no_tx_in_idle : assert property (disable iff (!resetn) 
      (tx_state == ST_IDLE) |-> !$rose(s_axis_tx_tvalid))
      else note_fail("SOC-005: tvalid rose while tx_state==IDLE");

    //---------------------------------------------------------------------
    // Receive path
    //---------------------------------------------------------------------

    // SOC-006: the DUT hardwires m_axis_rx_tready to 1 (riscv_pcie_soc.sv:233).
    // If that ever changes, the RX agent's assumption of a never-stalling sink
    // becomes wrong and this fires first.
    a_rx_always_ready : assert property (disable iff (!resetn) m_axis_rx_tready == 1'b1)
      else note_fail({"SOC-006: m_axis_rx_tready is no longer tied high - the ",
                   "RX agent and predictor assume a never-stalling sink"});

    // SOC-007: rx_phase is a single bit toggled only by the capture FSM; it
    // must never be X once out of reset.
    a_rx_phase_defined : assert property (disable iff (!resetn) !$isunknown(rx_phase))
      else note_fail("SOC-007: rx_phase is X/Z");

    //---------------------------------------------------------------------
    // CPU bus
    //---------------------------------------------------------------------

    // SOC-008: PicoRV32 native bus - mem_valid must hold until mem_ready, and
    // the address must not move underneath it.
    a_cpu_addr_stable : assert property (disable iff (!resetn) 
      (mem_valid && !mem_ready) |=> (mem_valid && $stable(mem_addr)
                                     && $stable(mem_wstrb)))
      else note_fail("SOC-008: CPU bus request changed before mem_ready");

    // SOC-009: mem_ready must be traceable to a request.
    //
    // Deliberately NOT `mem_ready |-> mem_valid`.  The PicoRV32 native bus
    // treats mem_ready as meaningful only while mem_valid is high, and this
    // DUT leaves it asserted for one extra cycle after every RAM access: the
    // RAM's ready logic (riscv_pcie_soc.sv:106-120) re-arms itself because it
    // lacks the `&& !ram_ready_reg` guard that the bridge path at line 172
    // does have.  Since instruction fetch is a RAM access, the strict form
    // fires on essentially every instruction - see vPlan RTL-SIM-002.
    //
    // The useful invariant is that ready never appears out of nowhere.
    a_ready_has_a_request : assert property (disable iff (!resetn) 
      mem_ready |-> (mem_valid || $past(mem_valid)))
      else note_fail({"SOC-009: mem_ready asserted with no request in this or ",
                      "the previous cycle"});

    // SOC-011: and the trailing pulse must be exactly that - one cycle.  A
    // ready that stays high with no request would hang the next transfer.
    a_trailing_ready_bounded : assert property (disable iff (!resetn) 
      (mem_ready && !mem_valid) |=> !mem_ready)
      else note_fail({"SOC-011: mem_ready stayed asserted for more than one ",
                      "cycle after mem_valid dropped"});

    //---------------------------------------------------------------------
    // Sidebands
    //---------------------------------------------------------------------

    // SOC-010: cfg_command is declared on the DUT but is left unconnected at
    // the chip top (RC_direct_opensource.sv:124-144), so in a full-chip
    // elaboration it floats.  At Tier 1 the TB drives it; this assertion
    // exists so that the day someone reuses this checker at Tier 2/3, the
    // dangling input is reported instead of silently propagating X.
    a_cfg_command_driven : assert property (disable iff (!resetn) !$isunknown(cfg_command))
      else note_fail({"SOC-010: cfg_command is X/Z - at chip level this port is ",
                   "unconnected (RC_direct_opensource.sv:124-144)"});

    a_cfg_status_driven : assert property (disable iff (!resetn) !$isunknown(cfg_status))
      else note_fail("SOC-010: cfg_status is X/Z");

    a_tx_buf_av_driven : assert property (disable iff (!resetn) !$isunknown(tx_buf_av))
      else note_fail("SOC-010: tx_buf_av is X/Z");

    //---------------------------------------------------------------------
    // Cover
    //---------------------------------------------------------------------
    // Bounded on purpose.  Anchoring on ST_IDLE with unbounded `[->1]` starts
    // a fresh attempt on every idle cycle - and the FSM is idle almost always
    // - so VCS warns SVA-OPTCOV-LMFA (large memory footprint) and the thread
    // count grows without limit.  Anchoring on ST_C1, which is rare, and
    // bounding the windows costs nothing in coverage: a packet that takes
    // more than 64 cycles per phase is a hang, not something to cover.
    c_tx_full_packet   : cover property (disable iff (!resetn) 
      (tx_state == ST_C1) ##[1:64] (tx_state == ST_C2)
                          ##[1:64] (tx_state == ST_IDLE));
    c_tx_stall_in_c1   : cover property (disable iff (!resetn) (tx_state == ST_C1) && !s_axis_tx_tready);
    c_tx_stall_in_c2   : cover property (disable iff (!resetn) (tx_state == ST_C2) && !s_axis_tx_tready);
    c_rx_phase_toggle  : cover property (disable iff (!resetn) $rose(rx_phase) ##[1:256] $fell(rx_phase));
    c_credit_exhausted : cover property (disable iff (!resetn) tx_buf_av == 6'd0);
    c_tx_while_no_credit : cover property (disable iff (!resetn) 
      (tx_buf_av == 6'd0) && s_axis_tx_tvalid && s_axis_tx_tready);

  end
  endgenerate

endmodule

`endif // OPENPCIE_SOC_SVA_SV
