//---------------------------------------------------------------------------
// openpcie_cfg_pkg - configuration/status sideband agent
//---------------------------------------------------------------------------
// Drives the sidebands a real host_bridge would present to the SoC, and
// publishes their value so the scoreboard can predict ERR_STATUS and
// PHY_STATUS readbacks.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_CFG_PKG_SV
`define OPENPCIE_CFG_PKG_SV

package openpcie_cfg_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import openpcie_types_pkg::*;

  //-----------------------------------------------------------------------
  // Item - a complete sideband state to apply
  //-----------------------------------------------------------------------
  class openpcie_cfg_item extends uvm_sequence_item;

    rand bit [15:0] cfg_status;
    rand bit [15:0] cfg_command;
    rand bit        err_fatal;
    rand bit [5:0]  tx_buf_av;
    rand int unsigned hold_cycles;

    `uvm_object_utils_begin(openpcie_cfg_item)
      `uvm_field_int(cfg_status,  UVM_ALL_ON)
      `uvm_field_int(cfg_command, UVM_ALL_ON)
      `uvm_field_int(err_fatal,   UVM_ALL_ON)
      `uvm_field_int(tx_buf_av,   UVM_ALL_ON)
      `uvm_field_int(hold_cycles, UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_object_utils_end

    function new(string name = "openpcie_cfg_item");
      super.new(name);
    endfunction

    // Reset value of tx_buf_av in silicon is the full buffer depth; drive
    // something plausible by default so firmware polling PHY_STATUS sees
    // credit rather than a permanently empty pipe.
    constraint c_defaults {
      soft err_fatal   == 1'b0;
      soft tx_buf_av   inside {[16:32]};
      soft hold_cycles inside {[1:50]};
    }

    function string convert2string();
      return $sformatf("cfg_status=%04h cfg_command=%04h err_fatal=%0b tx_buf_av=%0d",
                       cfg_status, cfg_command, err_fatal, tx_buf_av);
    endfunction

  endclass

  typedef uvm_sequencer #(openpcie_cfg_item) openpcie_cfg_sequencer;

  //-----------------------------------------------------------------------
  // Config
  //-----------------------------------------------------------------------
  class openpcie_cfg_agent_cfg extends uvm_object;
    cfg_vif_t vif;
    uvm_active_passive_enum is_active = UVM_ACTIVE;

    // Applied at time 0 before any sequence runs, so the DUT never samples X.
    bit [15:0] init_cfg_status  = 16'h0010;   // "capabilities list" style value
    bit [15:0] init_cfg_command = 16'h0006;   // MemEn | BusMaster
    bit        init_err_fatal   = 1'b0;
    bit [5:0]  init_tx_buf_av   = 6'd32;

    `uvm_object_utils(openpcie_cfg_agent_cfg)
    function new(string name = "openpcie_cfg_agent_cfg");
      super.new(name);
    endfunction
  endclass

  //-----------------------------------------------------------------------
  // Driver
  //-----------------------------------------------------------------------
  class openpcie_cfg_driver extends uvm_driver #(openpcie_cfg_item);
    `uvm_component_utils(openpcie_cfg_driver)

    openpcie_cfg_agent_cfg cfg;
    cfg_vif_t              vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(openpcie_cfg_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CFG/DRV", "no openpcie_cfg_agent_cfg in config DB")
      vif = cfg.vif;
    endfunction

    // Signals are driven directly rather than through a clocking-block output;
    // see the comment in openpcie_cfg_if.sv for why that interface has no
    // driving clocking block.
    task run_phase(uvm_phase phase);
      apply_defaults();
      forever begin
        seq_item_port.get_next_item(req);
        @(posedge vif.clk);
        vif.cfg_status                 <= req.cfg_status;
        vif.cfg_command                <= req.cfg_command;
        vif.cfg_msg_received_err_fatal <= req.err_fatal;
        vif.tx_buf_av                  <= req.tx_buf_av;
        `uvm_info("CFG/DRV", req.convert2string(), UVM_HIGH)
        repeat (req.hold_cycles) @(posedge vif.clk);
        seq_item_port.item_done();
      end
    endtask

    // Applied at time 0 with blocking assignments so the DUT's very first
    // sampled value is defined even before the first clock edge.
    virtual function void apply_defaults();
      vif.cfg_status                 = cfg.init_cfg_status;
      vif.cfg_command                = cfg.init_cfg_command;
      vif.cfg_msg_received_err_fatal = cfg.init_err_fatal;
      vif.tx_buf_av                  = cfg.init_tx_buf_av;
    endfunction
  endclass

  //-----------------------------------------------------------------------
  // Monitor
  //-----------------------------------------------------------------------
  class openpcie_cfg_monitor extends uvm_monitor;
    `uvm_component_utils(openpcie_cfg_monitor)

    openpcie_cfg_agent_cfg cfg;
    cfg_vif_t              vif;
    uvm_analysis_port #(openpcie_cfg_item) ap;

    // Latest observed state - the predictor reads this directly when it needs
    // to know what a status readback should return.
    openpcie_cfg_item current;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(openpcie_cfg_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CFG/MON", "no openpcie_cfg_agent_cfg in config DB")
      vif     = cfg.vif;
      current = openpcie_cfg_item::type_id::create("cfg_current");
    endfunction

    task run_phase(uvm_phase phase);
      openpcie_cfg_item prev = null;
      forever begin
        @(vif.mon_cb);
        current.cfg_status  = vif.mon_cb.cfg_status;
        current.cfg_command = vif.mon_cb.cfg_command;
        current.err_fatal   = vif.mon_cb.cfg_msg_received_err_fatal;
        current.tx_buf_av   = vif.mon_cb.tx_buf_av;

        if (prev == null || prev.cfg_status !== current.cfg_status
            || prev.cfg_command !== current.cfg_command
            || prev.err_fatal   !== current.err_fatal
            || prev.tx_buf_av   !== current.tx_buf_av) begin
          openpcie_cfg_item snap;
          $cast(snap, current.clone());
          ap.write(snap);
          prev = snap;
        end
      end
    endtask
  endclass

  //-----------------------------------------------------------------------
  // Agent
  //-----------------------------------------------------------------------
  class openpcie_cfg_agent extends uvm_agent;
    `uvm_component_utils(openpcie_cfg_agent)

    openpcie_cfg_agent_cfg cfg;
    openpcie_cfg_sequencer sequencer;
    openpcie_cfg_driver    driver;
    openpcie_cfg_monitor   monitor;

    uvm_analysis_port #(openpcie_cfg_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(openpcie_cfg_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CFG/AGT", "no openpcie_cfg_agent_cfg in config DB")
      uvm_config_db#(openpcie_cfg_agent_cfg)::set(this, "*", "cfg", cfg);

      is_active = cfg.is_active;
      monitor   = openpcie_cfg_monitor::type_id::create("monitor", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        sequencer = openpcie_cfg_sequencer::type_id::create("sequencer", this);
        driver    = openpcie_cfg_driver   ::type_id::create("driver",    this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      ap = monitor.ap;
      if (driver != null)
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

  //-----------------------------------------------------------------------
  // Sequences
  //-----------------------------------------------------------------------
  class openpcie_cfg_static_seq extends uvm_sequence #(openpcie_cfg_item);
    `uvm_object_utils(openpcie_cfg_static_seq)

    rand bit [15:0] cfg_status  = 16'h0010;
    rand bit [15:0] cfg_command = 16'h0006;
    rand bit [5:0]  tx_buf_av   = 6'd32;
    rand bit        err_fatal   = 1'b0;

    function new(string name = "openpcie_cfg_static_seq");
      super.new(name);
    endfunction

    task body();
      openpcie_cfg_item it = openpcie_cfg_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with {
        it.cfg_status  == local::cfg_status;
        it.cfg_command == local::cfg_command;
        it.tx_buf_av   == local::tx_buf_av;
        it.err_fatal   == local::err_fatal;
        it.hold_cycles == 1000;
      }) `uvm_fatal("CFG/SEQ", "randomize failed")
      finish_item(it);
    endtask
  endclass

  // Continuously varies the sidebands so status readbacks are never constant.
  class openpcie_cfg_random_seq extends uvm_sequence #(openpcie_cfg_item);
    `uvm_object_utils(openpcie_cfg_random_seq)

    rand int unsigned n_changes = 40;

    function new(string name = "openpcie_cfg_random_seq");
      super.new(name);
    endfunction

    task body();
      repeat (n_changes) begin
        openpcie_cfg_item it = openpcie_cfg_item::type_id::create("it");
        start_item(it);
        if (!it.randomize()) `uvm_fatal("CFG/SEQ", "randomize failed")
        finish_item(it);
      end
    endtask
  endclass

endpackage

`endif // OPENPCIE_CFG_PKG_SV
