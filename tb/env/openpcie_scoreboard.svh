//---------------------------------------------------------------------------
// openpcie_scoreboard
//---------------------------------------------------------------------------
// Two independent checks:
//
//  TX path   expected packets from the predictor are matched in order against
//            packets observed by the TX AXIS monitor.  In-order is correct
//            here: the bridge has a single transmit FSM with no reordering.
//
//  Readback  every firmware read of a bridge status register is compared with
//            the predictor's model of that register.
//
// The end-of-test check is as important as the per-item ones: a testbench that
// silently produced no traffic must fail, not pass.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_SCOREBOARD_SVH
`define OPENPCIE_SCOREBOARD_SVH

`uvm_analysis_imp_decl(_exp_tx)
`uvm_analysis_imp_decl(_act_tx)
`uvm_analysis_imp_decl(_rdbk)

class openpcie_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(openpcie_scoreboard)

  uvm_analysis_imp_exp_tx #(openpcie_axis_pkg::openpcie_axis_item, openpcie_scoreboard) exp_tx_imp;
  uvm_analysis_imp_act_tx #(openpcie_axis_pkg::openpcie_axis_item, openpcie_scoreboard) act_tx_imp;
  uvm_analysis_imp_rdbk   #(openpcie_cpu_pkg::openpcie_cpu_item,   openpcie_scoreboard) rdbk_imp;

  openpcie_predictor predictor;

  // Set by the env; when 0 the scoreboard observes but does not fail.
  bit enable_tx_check      = 1;
  bit enable_rdbk_check    = 1;
  // A test that legitimately produces no TX traffic sets this to 0.
  bit require_tx_activity  = 1;

  // A systemic DUT defect corrupts every packet, and in-order matching then
  // cascades: once framing breaks, each observed packet is compared against
  // the wrong expected one and the report becomes unreadable.  Report the
  // first N mismatches in full, then count silently.  The total always
  // appears in report_phase, so nothing is hidden.
  int unsigned max_reported_mismatches = 10;

  protected openpcie_axis_pkg::openpcie_axis_item m_exp_q[$];
  protected openpcie_axis_pkg::openpcie_axis_item m_act_q[$];

  int unsigned tx_matched;
  int unsigned tx_mismatched;
  int unsigned rdbk_checked;
  int unsigned rdbk_skipped;
  int unsigned rdbk_mismatched;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    exp_tx_imp = new("exp_tx_imp", this);
    act_tx_imp = new("act_tx_imp", this);
    rdbk_imp   = new("rdbk_imp",   this);
  endfunction

  //-----------------------------------------------------------------------
  // TX path
  //-----------------------------------------------------------------------
  virtual function void write_exp_tx(openpcie_axis_pkg::openpcie_axis_item t);
    m_exp_q.push_back(t);
    try_match();
  endfunction

  virtual function void write_act_tx(openpcie_axis_pkg::openpcie_axis_item t);
    m_act_q.push_back(t);
    try_match();
  endfunction

  protected virtual function void try_match();
    while (m_exp_q.size() > 0 && m_act_q.size() > 0) begin
      openpcie_axis_pkg::openpcie_axis_item e = m_exp_q.pop_front();
      openpcie_axis_pkg::openpcie_axis_item a = m_act_q.pop_front();
      compare_packet(e, a);
    end
  endfunction

  protected virtual function void compare_packet(
      openpcie_axis_pkg::openpcie_axis_item e,
      openpcie_axis_pkg::openpcie_axis_item a);

    string diff = "";

    if (e.n_beats() != a.n_beats()) begin
      diff = $sformatf("beat count: expected %0d, observed %0d",
                       e.n_beats(), a.n_beats());
    end
    else begin
      foreach (e.data[i]) begin
        if (e.data[i] !== a.data[i])
          diff = {diff, $sformatf({"\n  beat %0d tdata: expected %016h, ",
                                   "observed %016h"}, i, e.data[i], a.data[i])};
        if (e.keep[i] !== a.keep[i])
          diff = {diff, $sformatf({"\n  beat %0d tkeep: expected %02h, ",
                                   "observed %02h"}, i, e.keep[i], a.keep[i])};
      end
    end

    if (diff == "") begin
      tx_matched++;
      `uvm_info("SCBD", $sformatf("TX packet #%0d matches", tx_matched),
                UVM_HIGH)
    end
    else begin
      tx_mismatched++;
      if (!enable_tx_check)
        `uvm_info("SCBD/TX", $sformatf("TX mismatch (checking disabled)%s",
                  diff), UVM_LOW)
      else if (tx_mismatched <= max_reported_mismatches)
        `uvm_error("SCBD/TX", $sformatf(
          "TX packet mismatch (#%0d observed)%s\nEXPECTED:\n%s\nOBSERVED:\n%s",
          tx_matched + tx_mismatched, diff,
          e.convert2string(), a.convert2string()))
      else if (tx_mismatched == max_reported_mismatches + 1)
        `uvm_error("SCBD/TX", $sformatf(
          {"TX packet mismatch #%0d - suppressing further per-packet reports ",
           "(max_reported_mismatches=%0d). Once packet framing breaks, ",
           "in-order matching compares every later packet against the wrong ",
           "expectation, so the rest add noise rather than information. The ",
           "total is reported at end of test."},
          tx_matched + tx_mismatched, max_reported_mismatches))
    end
  endfunction

  //-----------------------------------------------------------------------
  // Status readback
  //-----------------------------------------------------------------------
  virtual function void write_rdbk(openpcie_cpu_pkg::openpcie_cpu_item t);
    bit [31:0] exp, mask;

    if (!t.to_bridge) return;
    if (t.dir != openpcie_cpu_pkg::CPU_READ) return;
    if (predictor == null) return;

    if (!predictor.expected_read(t.bridge_offset, exp, mask)) begin
      rdbk_skipped++;
      `uvm_info("SCBD/RD", $sformatf(
        "skipping readback check at +0x%02h (value not yet predictable)",
        t.bridge_offset), UVM_HIGH)
      return;
    end

    rdbk_checked++;
    if ((t.rdata & mask) !== (exp & mask)) begin
      rdbk_mismatched++;
      if (enable_rdbk_check)
        `uvm_error("SCBD/RD", $sformatf(
          {"bridge readback mismatch at +0x%02h: expected %08h, observed %08h ",
           "(compare mask %08h)"}, t.bridge_offset, exp, t.rdata, mask))
    end
  endfunction

  //-----------------------------------------------------------------------
  // End of test
  //-----------------------------------------------------------------------
  function void check_phase(uvm_phase phase);
    if (m_exp_q.size() != 0)
      `uvm_error("SCBD/TX", $sformatf(
        {"%0d predicted TX packet(s) were never transmitted by the DUT - ",
         "the first missing one is:\n%s"},
        m_exp_q.size(), m_exp_q[0].convert2string()))

    if (m_act_q.size() != 0)
      `uvm_error("SCBD/TX", $sformatf(
        {"%0d TX packet(s) were transmitted that the model did not predict - ",
         "the first unexpected one is:\n%s"},
        m_act_q.size(), m_act_q[0].convert2string()))

    if (require_tx_activity && tx_matched == 0 && tx_mismatched == 0)
      `uvm_error("SCBD", {"no TX packet was checked - the test exercised ",
                          "nothing. Set require_tx_activity=0 if this is ",
                          "intentional."})
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SCBD", $sformatf(
      {"TX packets: %0d matched, %0d mismatched | readbacks: %0d checked, ",
       "%0d mismatched, %0d skipped"},
      tx_matched, tx_mismatched, rdbk_checked, rdbk_mismatched, rdbk_skipped),
      UVM_LOW)
  endfunction

endclass

`endif // OPENPCIE_SCOREBOARD_SVH
