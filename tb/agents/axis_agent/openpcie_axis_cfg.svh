//---------------------------------------------------------------------------
// openpcie_axis_cfg - per-agent configuration
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_CFG_SVH
`define OPENPCIE_AXIS_CFG_SVH

class openpcie_axis_cfg extends uvm_object;

  axis_vif_t        vif;

  axis_role_e       role       = AXIS_ROLE_MASTER;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit               enable_coverage = 1;
  bit               enable_checks   = 1;
  // Score packet-shape coverage against what the Tier 1 bridge can produce
  // (two beats, 12 or 16 bytes).  Read at coverage construction.
  bit               tier1_shapes    = 0;

  // Backpressure shaping, slave role only.
  rand axis_ready_mode_e ready_mode   = READY_ALWAYS;
  rand int unsigned      ready_pct    = 70;   // READY_RANDOM: P(tready) %
  rand int unsigned      ready_period = 4;    // READY_SLOW:  1 accept per N
  rand int unsigned      burst_accept = 4;    // READY_BURST: accept run
  rand int unsigned      burst_stall  = 2;    // READY_BURST: stall run

  // Human-readable tag used in messages and coverage instance names.
  string            name_tag = "axis";

  `uvm_object_utils_begin(openpcie_axis_cfg)
    `uvm_field_enum(axis_role_e,       role,         UVM_ALL_ON)
    `uvm_field_enum(uvm_active_passive_enum, is_active, UVM_ALL_ON)
    `uvm_field_enum(axis_ready_mode_e, ready_mode,   UVM_ALL_ON)
    `uvm_field_int (ready_pct,                       UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (ready_period,                    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (burst_accept,                    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (burst_stall,                     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (enable_coverage,                 UVM_ALL_ON)
    `uvm_field_int (enable_checks,                   UVM_ALL_ON)
    `uvm_field_int (tier1_shapes,                    UVM_ALL_ON)
    `uvm_field_string(name_tag,                      UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "openpcie_axis_cfg");
    super.new(name);
  endfunction

  constraint c_ready {
    ready_pct    inside {[5:100]};
    ready_period inside {[1:16]};
    burst_accept inside {[1:16]};
    burst_stall  inside {[1:16]};
  }

endclass

`endif // OPENPCIE_AXIS_CFG_SVH
