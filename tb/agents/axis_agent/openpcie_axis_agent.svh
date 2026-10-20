//---------------------------------------------------------------------------
// openpcie_axis_agent
//---------------------------------------------------------------------------
// One agent class covers all three roles.  Which sub-components exist is a
// function of (role, is_active):
//
//   MASTER + ACTIVE   sequencer + driver + monitor [+ coverage]
//   SLAVE  + ACTIVE   responder + monitor          [+ coverage]
//   any    + PASSIVE  monitor                      [+ coverage]
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_AGENT_SVH
`define OPENPCIE_AXIS_AGENT_SVH

typedef uvm_sequencer #(openpcie_axis_item) openpcie_axis_sequencer;

class openpcie_axis_agent extends uvm_agent;

  `uvm_component_utils(openpcie_axis_agent)

  openpcie_axis_cfg        cfg;

  openpcie_axis_sequencer  sequencer;
  openpcie_axis_driver     driver;
  openpcie_axis_responder  responder;
  openpcie_axis_monitor    monitor;
  openpcie_axis_coverage   coverage;

  // Re-exported so the env can connect without reaching into `monitor`.
  uvm_analysis_port #(openpcie_axis_item) ap;
  uvm_analysis_port #(openpcie_axis_item) beat_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(openpcie_axis_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXIS/AGT", $sformatf(
        "no openpcie_axis_cfg for %s - the env must set it before build",
        get_full_name()))

    // Republish for the children so each one can `get` it uniformly.
    uvm_config_db#(openpcie_axis_cfg)::set(this, "*", "cfg", cfg);

    is_active = cfg.is_active;

    monitor = openpcie_axis_monitor::type_id::create("monitor", this);

    if (cfg.enable_coverage)
      coverage = openpcie_axis_coverage::type_id::create("coverage", this);

    if (cfg.is_active == UVM_ACTIVE) begin
      case (cfg.role)
        AXIS_ROLE_MASTER : begin
          sequencer = openpcie_axis_sequencer::type_id::create("sequencer", this);
          driver    = openpcie_axis_driver   ::type_id::create("driver",    this);
        end
        AXIS_ROLE_SLAVE : begin
          responder = openpcie_axis_responder::type_id::create("responder", this);
        end
        default : /* monitor-only */ ;
      endcase
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    ap      = monitor.ap;
    beat_ap = monitor.beat_ap;

    if (coverage != null)
      monitor.ap.connect(coverage.analysis_export);

    if (driver != null && sequencer != null)
      driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction

endclass

`endif // OPENPCIE_AXIS_AGENT_SVH
