//---------------------------------------------------------------------------
// openpcie_axis_responder - AXI4-Stream sink (slave role)
//---------------------------------------------------------------------------
// Owns tready on the DUT's s_axis_tx_* port.  Its whole purpose is to make
// backpressure interesting: the DUT's transmit FSM samples tready one cycle
// before the corresponding beat is presented (riscv_pcie_soc.sv:195-211), so
// an always-ready sink hides the bug and a stalling sink exposes it.
//
// Shapes available (openpcie_types_pkg::axis_ready_mode_e):
//   READY_ALWAYS  tready tied high - the permissive baseline
//   READY_RANDOM  Bernoulli per cycle at cfg.ready_pct
//   READY_BURST   alternating accept/stall runs
//   READY_SLOW    one accept every cfg.ready_period cycles
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_RESPONDER_SVH
`define OPENPCIE_AXIS_RESPONDER_SVH

class openpcie_axis_responder extends uvm_component;

  `uvm_component_utils(openpcie_axis_responder)

  openpcie_axis_cfg cfg;
  axis_vif_t        vif;

  // Statistics the report phase surfaces so a test can tell at a glance
  // whether it actually stressed the interface.
  int unsigned stall_cycles;
  int unsigned accept_cycles;
  int unsigned longest_stall;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(openpcie_axis_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXIS/RSP", "no openpcie_axis_cfg in config DB")
    vif = cfg.vif;
  endfunction

  // tready is driven directly rather than through a clocking-block output;
  // see the comment in openpcie_axis_if.sv for why that interface has no
  // driving clocking block.
  task run_phase(uvm_phase phase);
    vif.tready <= 1'b0;
    @(posedge vif.clk iff vif.rst_n);

    forever begin
      fork
        begin : shape
          case (cfg.ready_mode)
            READY_ALWAYS : drive_always();
            READY_RANDOM : drive_random();
            READY_BURST  : drive_burst();
            READY_SLOW   : drive_slow();
            default      : drive_always();
          endcase
        end
        begin : watch_reset
          @(negedge vif.rst_n);
        end
      join_any
      disable fork;
      vif.tready <= 1'b0;
      @(posedge vif.rst_n);
    end
  endtask

  // Track how long tready has been low while the source is offering a beat -
  // that is the metric that matters, not raw idle time.
  local task automatic tick(bit ready);
    vif.tready <= ready;
    @(posedge vif.clk);
    if (vif.mon_cb.tvalid === 1'b1) begin
      if (ready) begin
        accept_cycles++;
        longest_stall = 0;
      end
      else begin
        stall_cycles++;
        longest_stall++;
      end
    end
  endtask

  virtual task drive_always();
    forever tick(1'b1);
  endtask

  virtual task drive_random();
    forever begin
      bit r;
      // $urandom_range is seeded per-instance by the UVM RNG, so runs stay
      // reproducible under -uvm_set_config / +ntb_random_seed.
      r = ($urandom_range(99, 0) < cfg.ready_pct);
      tick(r);
    end
  endtask

  virtual task drive_burst();
    forever begin
      repeat (cfg.burst_accept) tick(1'b1);
      repeat (cfg.burst_stall)  tick(1'b0);
    end
  endtask

  virtual task drive_slow();
    forever begin
      tick(1'b1);
      repeat (cfg.ready_period - 1) tick(1'b0);
    end
  endtask

  function void report_phase(uvm_phase phase);
    int unsigned tot = stall_cycles + accept_cycles;
    `uvm_info("AXIS/RSP", $sformatf(
      "mode=%s  offered cycles=%0d  accepted=%0d  stalled=%0d (%0d%%)",
      cfg.ready_mode.name(), tot, accept_cycles, stall_cycles,
      (tot == 0) ? 0 : (100 * stall_cycles) / tot), UVM_LOW)

    // A backpressure test that never stalled proves nothing; say so loudly.
    if (cfg.ready_mode != READY_ALWAYS && stall_cycles == 0 && tot > 0)
      `uvm_warning("AXIS/RSP", $sformatf(
        {"ready_mode=%s but no beat was ever stalled - the test did not ",
         "exercise backpressure"}, cfg.ready_mode.name()))
  endfunction

endclass

`endif // OPENPCIE_AXIS_RESPONDER_SVH
