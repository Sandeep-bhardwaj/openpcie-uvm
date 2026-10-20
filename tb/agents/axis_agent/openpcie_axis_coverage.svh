//---------------------------------------------------------------------------
// openpcie_axis_coverage - functional coverage on the stream interface
//---------------------------------------------------------------------------
// Interface-level coverage only.  TLP-level and cross-block coverage lives in
// tb/env/openpcie_soc_coverage.svh so that this agent stays reusable at
// Tier 2 without dragging Tier 1 semantics along.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_COVERAGE_SVH
`define OPENPCIE_AXIS_COVERAGE_SVH

class openpcie_axis_coverage extends uvm_subscriber #(openpcie_axis_item);

  `uvm_component_utils(openpcie_axis_coverage)

  openpcie_axis_cfg cfg;

  // Sampled from the packet stream.
  int unsigned  cv_beats;
  int unsigned  cv_bytes;
  bit [7:0]     cv_last_keep;

  // Every shape the interface can carry.  Weight is 1 normally; with
  // cfg.tier1_shapes it drops to 0 and cg_packet_t1 carries the goal, so the
  // tally is kept but shapes the Tier 1 bridge cannot produce are not counted
  // as holes.
  covergroup cg_packet(int w);
    option.per_instance = 1;
    option.name         = "axis_packet";
    option.weight       = w;

    // The Tier 1 bridge always emits exactly 2 beats; anything else is either
    // a Tier 2 shape or a bug worth noticing.
    //
    // `zero` is a legitimate illegal_bin because it can only mean the *monitor*
    // is broken: it pushes a beat before it tests tlast, so an emitted packet
    // always has at least one.  No DUT behaviour can reach it.  Contrast
    // openpcie_soc_coverage's x_fmt_keep, where illegal bins were removed
    // precisely because a DUT defect could trip them.
    cp_beats : coverpoint cv_beats {
      bins one          = {1};
      bins two          = {2};
      bins three_to_four= {[3:4]};
      bins many         = {[5:64]};
      illegal_bins zero = {0};
    }

    // 0x0F means the packet ended on a 3 DW header with no payload DW;
    // 0xFF means the final beat carried a full 64 bits.
    cp_last_keep : coverpoint cv_last_keep {
      bins hdr_only  = {8'h0F};
      bins full      = {8'hFF};
      bins other[]   = {8'h01, 8'h03, 8'h07, 8'h1F, 8'h3F, 8'h7F};
    }

    cp_bytes : coverpoint cv_bytes {
      bins b12  = {12};          // 3 DW header, no payload
      bins b16  = {16};          // 3 DW header + 1 DW payload
      bins b20  = {20};
      bins mid  = {[21:64]};
      bins big  = {[65:4096]};
    }

    x_beats_keep : cross cp_beats, cp_last_keep;
  endgroup

  // Tier 1 goal: the bridge sends and accepts exactly two beats - a 3 DW
  // header plus at most one payload DW - so 12 or 16 bytes.
  covergroup cg_packet_t1;
    option.per_instance = 1;
    option.name         = "axis_packet_t1";

    cp_beats : coverpoint cv_beats { bins two = {2}; }

    cp_last_keep : coverpoint cv_last_keep {
      bins hdr_only = {8'h0F};
      bins full     = {8'hFF};
    }

    cp_bytes : coverpoint cv_bytes {
      bins b12 = {12};
      bins b16 = {16};
    }
  endgroup

  // Embedded covergroups must be built here, not in build_phase, so the cfg
  // is fetched now - the agent publishes it before creating this component.
  // m_t1 rather than a null test on cg_packet_t1: xsim cannot compare an
  // embedded covergroup handle (XSIM 43-3254).
  bit m_t1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    if (uvm_config_db#(openpcie_axis_cfg)::get(this, "", "cfg", cfg))
      m_t1 = cfg.tier1_shapes;
    cg_packet = new(m_t1 ? 0 : 1);
    if (m_t1) cg_packet_t1 = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(openpcie_axis_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXIS/COV", "no openpcie_axis_cfg in config DB")
  endfunction

  function void write(openpcie_axis_item t);
    if (!cfg.enable_coverage) return;
    cv_beats     = t.n_beats();
    cv_bytes     = t.n_bytes();
    cv_last_keep = t.keep[t.keep.size()-1];
    cg_packet.sample();
    if (m_t1) cg_packet_t1.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    if (cfg.enable_coverage)
      `uvm_info("AXIS/COV", $sformatf("%s: packet coverage %0.2f%%",
                cfg.name_tag, m_t1
                                ? cg_packet_t1.get_inst_coverage()
                                : cg_packet.get_inst_coverage()), UVM_LOW)
  endfunction

endclass

`endif // OPENPCIE_AXIS_COVERAGE_SVH
