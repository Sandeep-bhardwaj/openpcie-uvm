//---------------------------------------------------------------------------
// openpcie_soc_coverage - Tier 1 functional coverage
//---------------------------------------------------------------------------
// Cross-block coverage that only makes sense with knowledge of the SoC's
// semantics.  Interface-shape coverage stays in the AXIS agent.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_SOC_COVERAGE_SVH
`define OPENPCIE_SOC_COVERAGE_SVH

`uvm_analysis_imp_decl(_cov_cpu)
`uvm_analysis_imp_decl(_cov_tx)
`uvm_analysis_imp_decl(_cov_cfg)

class openpcie_soc_coverage extends uvm_component;

  `uvm_component_utils(openpcie_soc_coverage)

  uvm_analysis_imp_cov_cpu #(openpcie_cpu_pkg::openpcie_cpu_item,   openpcie_soc_coverage) cpu_imp;
  uvm_analysis_imp_cov_tx  #(openpcie_axis_pkg::openpcie_axis_item, openpcie_soc_coverage) tx_imp;
  uvm_analysis_imp_cov_cfg #(openpcie_cfg_pkg::openpcie_cfg_item,   openpcie_soc_coverage) cfg_imp;

  bit enable = 1;

  // ---- sampled state ---------------------------------------------------
  bit [5:0]  cv_offset;
  bit        cv_is_write;
  bit [4:0]  cv_tlp_type;
  bit [1:0]  cv_tlp_fmt;
  bit [9:0]  cv_tlp_len;
  bit [7:0]  cv_last_keep;
  bit [5:0]  cv_tx_buf_av;
  bit [15:0] cv_cfg_status;
  bit        cv_err_fatal;

  //-----------------------------------------------------------------------
  covergroup cg_reg_access;
    option.per_instance = 1;
    option.name         = "bridge_register_access";

    cp_offset : coverpoint cv_offset {
      bins tx_hdr0     = {6'h00};
      bins tx_hdr1     = {6'h04};
      bins tx_hdr2     = {6'h08};
      bins tx_data     = {6'h0C};
      bins rx_status   = {6'h10};
      bins rx_data     = {6'h14};
      bins rx_hdr_info = {6'h18};
      bins err_status  = {6'h1C};
      bins phy_status  = {6'h20};
      bins aliased     = default;
    }

    cp_dir : coverpoint cv_is_write { bins wr = {1}; bins rd = {0}; }

    // Reading a write-only register and writing a read-only one are both
    // legal-but-odd; make sure the suite actually tries them.
    x_offset_dir : cross cp_offset, cp_dir;
  endgroup

  //-----------------------------------------------------------------------
  covergroup cg_tlp;
    option.per_instance = 1;
    option.name         = "transmitted_tlp";

    cp_type : coverpoint cv_tlp_type {
      bins mem  = {5'b00000};
      bins io   = {5'b00010};
      bins cfg0 = {5'b00100};
      bins cfg1 = {5'b00101};
      bins cpl  = {5'b01010};
      // Messages always carry a 4 DW header, which the Tier 1 bridge cannot
      // emit - out of the Tier 1 goal, not a hole.
      ignore_bins msg = {5'b10000};
      bins other= default;
    }

    // The bridge emits exactly three header DWs, so a 4 DW Fmt cannot be
    // sent as a well-formed TLP at Tier 1.  Tier 2 restores these bins.
    cp_fmt : coverpoint cv_tlp_fmt {
      bins dw3_nodata = {2'b00};
      bins dw3_data   = {2'b10};
      ignore_bins dw4 = {2'b01, 2'b11};
    }

    // NOTE: `small`, `medium` and `large` are SystemVerilog charge-strength
    // keywords and cannot be used as bin names.
    cp_len : coverpoint cv_tlp_len {
      bins one     = {1};
      bins few_dw  = {[2:8]};
      bins mid_dw  = {[9:64]};
      bins many_dw = {[65:1023]};
      bins max1k   = {0};      // 0 encodes 1024 DW
    }

    // The final beat's tkeep is derived from Fmt[1]; the cross proves the
    // DUT's tkeep selection tracked the header on every combination seen.
    cp_last_keep : coverpoint cv_last_keep {
      bins hdr_only = {8'h0F};
      bins with_dw  = {8'hFF};
    }

    // Fmt[1]=1 must produce a full final beat and Fmt[1]=0 a partial one.
    // Only the two conforming combinations are in the goal; the two
    // non-conforming ones are tallied in cg_tlp_diag below.
    x_fmt_keep : cross cp_fmt, cp_last_keep {
      bins ok_nodata_partial =
        binsof(cp_fmt.dw3_nodata) && binsof(cp_last_keep.hdr_only);
      bins ok_data_full =
        binsof(cp_fmt.dw3_data)   && binsof(cp_last_keep.with_dw);
      ignore_bins non_conforming =
        (binsof(cp_fmt.dw3_nodata) && binsof(cp_last_keep.with_dw)) ||
        (binsof(cp_fmt.dw3_data)   && binsof(cp_last_keep.hdr_only));
    }

    x_type_fmt : cross cp_type, cp_fmt;
  endgroup

  //-----------------------------------------------------------------------
  // Diagnostic tally of non-conforming Fmt/tkeep pairs.  Expected to stay
  // empty against correct RTL, so it carries zero weight: an empty bin here
  // is the good outcome and must not pull the score down.
  //
  // These were once `illegal_bins` in cg_tlp, which was a mistake.  Illegal
  // bins are for conditions that mean the *testbench* is misconfigured; a DUT
  // defect must be reported by a checker that can explain it.  Under
  // backpressure the TX FSM corrupts beat 0 (vPlan TX-PROTO-004), so the
  // covergroup samples a garbled DW0 - an illegal bin then turned an
  // informative "payload changed during a stall" into an opaque
  // `Error-[FCIBH] Illegal bin hit` and aborted the run before the scoreboard
  // could report anything.  The real checks are SVA SOC-003 / SOC-004 and the
  // scoreboard's packet compare.
  covergroup cg_tlp_diag;
    option.per_instance = 1;
    option.name         = "tlp_fmt_keep_diag";
    option.weight       = 0;

    // {Fmt[1], final tkeep}
    cp_bad : coverpoint {cv_tlp_fmt[1], cv_last_keep} {
      bins bad_nodata_full  = {9'h0FF};
      bins bad_data_partial = {9'h10F};
    }
  endgroup

  //-----------------------------------------------------------------------
  covergroup cg_sideband;
    option.per_instance = 1;
    option.name         = "sidebands";

    // Credit exhaustion is the interesting corner: the DUT never checks
    // tx_buf_av before transmitting, so covering 0 documents that the
    // condition was actually presented (see vplan TX-FLOW-001).
    cp_tx_buf_av : coverpoint cv_tx_buf_av {
      bins empty     = {0};
      bins nearly    = {[1:3]};
      bins some      = {[4:31]};
      bins full      = {[32:63]};
    }

    cp_err_fatal : coverpoint cv_err_fatal { bins clear = {0}; bins set = {1}; }

    cp_cfg_status : coverpoint cv_cfg_status {
      bins zero   = {16'h0000};
      bins allset = {16'hFFFF};
      bins other  = default;
    }

    x_credit_err : cross cp_tx_buf_av, cp_err_fatal;
  endgroup

  //-----------------------------------------------------------------------
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cpu_imp = new("cpu_imp", this);
    tx_imp  = new("tx_imp",  this);
    cfg_imp = new("cfg_imp", this);
    cg_reg_access = new();
    cg_tlp        = new();
    cg_tlp_diag   = new();
    cg_sideband   = new();
  endfunction

  virtual function void write_cov_cpu(openpcie_cpu_pkg::openpcie_cpu_item t);
    if (!enable || !t.to_bridge) return;
    cv_offset   = t.bridge_offset[5:0];
    cv_is_write = (t.dir == openpcie_cpu_pkg::CPU_WRITE);
    cg_reg_access.sample();
  endfunction

  virtual function void write_cov_tx(openpcie_axis_pkg::openpcie_axis_item t);
    bit [31:0] dw0;
    if (!enable || t.n_beats() == 0) return;
    dw0          = t.data[0][31:0];
    cv_tlp_fmt   = dw0[30:29];
    cv_tlp_type  = dw0[28:24];
    cv_tlp_len   = dw0[9:0];
    cv_last_keep = t.keep[t.keep.size()-1];
    cg_tlp.sample();
    cg_tlp_diag.sample();
  endfunction

  virtual function void write_cov_cfg(openpcie_cfg_pkg::openpcie_cfg_item c);
    if (!enable) return;
    cv_tx_buf_av  = c.tx_buf_av;
    cv_err_fatal  = c.err_fatal;
    cv_cfg_status = c.cfg_status;
    cg_sideband.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    if (!enable) return;
    `uvm_info("COV", $sformatf(
      "functional coverage - reg_access %0.2f%%, tlp %0.2f%%, sideband %0.2f%%",
      cg_reg_access.get_inst_coverage(),
      cg_tlp.get_inst_coverage(),
      cg_sideband.get_inst_coverage()), UVM_LOW)
    if (cg_tlp_diag.get_inst_coverage() > 0.0)
      `uvm_info("COV", {"non-conforming Fmt/tkeep pairs were transmitted ",
                        "(cg_tlp_diag) - see the SOC-003/004 and scoreboard ",
                        "reports for the cause"}, UVM_LOW)
  endfunction

endclass

`endif // OPENPCIE_SOC_COVERAGE_SVH
