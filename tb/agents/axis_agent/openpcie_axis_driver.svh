//---------------------------------------------------------------------------
// openpcie_axis_driver - AXI4-Stream source (master role)
//---------------------------------------------------------------------------
// Drives tdata/tkeep/tuser/tlast/tvalid onto the DUT's m_axis_rx_* port.
//
// Protocol obligations honoured here (AMBA AXI4-Stream, section 2.2.1):
//   * once tvalid is asserted it stays asserted until tready is seen
//   * tdata/tkeep/tuser/tlast are held stable across a stall
//   * tvalid is deasserted during reset and no beat survives a reset
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_DRIVER_SVH
`define OPENPCIE_AXIS_DRIVER_SVH

class openpcie_axis_driver extends uvm_driver #(openpcie_axis_item);

  `uvm_component_utils(openpcie_axis_driver)

  openpcie_axis_cfg cfg;
  axis_vif_t        vif;

  int unsigned beats_driven;
  int unsigned packets_driven;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(openpcie_axis_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXIS/DRV", "no openpcie_axis_cfg in config DB")
    if (cfg.vif == null)
      `uvm_fatal("AXIS/DRV", "openpcie_axis_cfg.vif is null")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    idle();
    forever begin
      fork
        begin : drive
          @(posedge vif.clk iff vif.rst_n);
          forever begin
            seq_item_port.get_next_item(req);
            drive_packet(req);
            seq_item_port.item_done();
          end
        end
        begin : watch_reset
          @(negedge vif.rst_n);
          `uvm_info("AXIS/DRV", "reset asserted - dropping in-flight packet",
                    UVM_MEDIUM)
        end
      join_any
      disable fork;
      idle();
      @(posedge vif.rst_n);
    end
  endtask

  // Signals are driven directly rather than through a clocking-block output;
  // see the comment in openpcie_axis_if.sv for why that interface has no
  // driving clocking block.
  virtual task idle();
    vif.tvalid <= 1'b0;
    vif.tlast  <= 1'b0;
    vif.tdata  <= '0;
    vif.tkeep  <= '0;
    vif.tuser  <= '0;
  endtask

  virtual task drive_packet(openpcie_axis_item it);
    `uvm_info("AXIS/DRV", $sformatf("driving %0d-beat packet", it.n_beats()),
              UVM_HIGH)

    foreach (it.data[i]) begin
      // Idle gap before offering this beat.
      repeat (it.pre_beat_delay.size() > i ? it.pre_beat_delay[i] : 0) begin
        vif.tvalid <= 1'b0;
        @(posedge vif.clk);
      end

      vif.tdata  <= it.data[i];
      vif.tkeep  <= it.keep[i];
      vif.tuser  <= (it.user.size() > i) ? it.user[i] : '0;
      vif.tlast  <= (i == it.n_beats() - 1);
      vif.tvalid <= 1'b1;

      // Hold everything stable until the sink accepts.  `mon_cb.tready` is
      // sampled with #1step, i.e. the value immediately before the edge, which
      // is the correct handshake sample for the beat presented since the
      // previous edge.  Sampling tready *after* the beat is visible is what
      // makes this a legal AXI4-Stream source - the DUT's TX FSM does the
      // opposite, which is the defect TX-PROTO-004 targets.
      do begin
        @(posedge vif.clk);
      end while (vif.mon_cb.tready !== 1'b1);

      beats_driven++;
    end

    vif.tvalid <= 1'b0;
    vif.tlast  <= 1'b0;
    packets_driven++;

    repeat (it.inter_packet_gap) @(posedge vif.clk);
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("AXIS/DRV", $sformatf("drove %0d packet(s), %0d beat(s)",
              packets_driven, beats_driven), UVM_LOW)
  endfunction

endclass

`endif // OPENPCIE_AXIS_DRIVER_SVH
