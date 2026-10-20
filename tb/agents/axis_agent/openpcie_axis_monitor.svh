//---------------------------------------------------------------------------
// openpcie_axis_monitor - passive AXI4-Stream observer
//---------------------------------------------------------------------------
// Reassembles beats into packets and publishes them on `ap`.  It also performs
// the in-monitor protocol checks that are awkward to express in SVA because
// they need packet history (stability across a stall, tkeep legality relative
// to position in the packet).  Cycle-local rules live in sva/ instead.
//
// The monitor is role-agnostic: the same class instance serves the master-side
// and slave-side agents, which is what lets the scoreboard compare a packet
// injected on RX against the packet observed on TX.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_MONITOR_SVH
`define OPENPCIE_AXIS_MONITOR_SVH

class openpcie_axis_monitor extends uvm_monitor;

  `uvm_component_utils(openpcie_axis_monitor)

  openpcie_axis_cfg cfg;
  axis_vif_t        vif;

  uvm_analysis_port #(openpcie_axis_item) ap;        // completed packets
  uvm_analysis_port #(openpcie_axis_item) beat_ap;   // single-beat, for coverage

  int unsigned packets_seen;
  int unsigned beats_seen;
  int unsigned protocol_errors;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap      = new("ap", this);
    beat_ap = new("beat_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(openpcie_axis_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXIS/MON", "no openpcie_axis_cfg in config DB")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      fork
        collect();
        @(negedge vif.rst_n);
      join_any
      disable fork;
      `uvm_info("AXIS/MON", "reset - discarding partial packet", UVM_HIGH)
      @(posedge vif.rst_n);
    end
  endtask

  virtual task collect();
    openpcie_axis_item pkt;
    bit [AXIS_DATA_W-1:0] d_q[$];
    bit [AXIS_KEEP_W-1:0] k_q[$];
    bit [AXIS_USER_W-1:0] u_q[$];
    time  t0;
    bit   in_packet = 0;

    // Stability tracking across stalls.
    bit                   held        = 0;
    bit [AXIS_DATA_W-1:0] held_data;
    bit [AXIS_KEEP_W-1:0] held_keep;
    bit                   held_last;

    @(posedge vif.clk iff vif.rst_n);

    forever begin
      @(vif.mon_cb);

      if (vif.mon_cb.tvalid !== 1'b1) begin
        if (held && cfg.enable_checks) begin
          protocol_errors++;
          `uvm_error("AXIS/PROTO", $sformatf(
            {"%s: tvalid deasserted while a beat was still unaccepted ",
             "(AXI4-Stream 2.2.1: tvalid must remain high until tready)"},
            cfg.name_tag))
        end
        held = 0;
        continue;
      end

      // ---- tvalid is high --------------------------------------------
      if (held && cfg.enable_checks) begin
        if (vif.mon_cb.tdata !== held_data || vif.mon_cb.tkeep !== held_keep ||
            vif.mon_cb.tlast !== held_last) begin
          protocol_errors++;
          `uvm_error("AXIS/PROTO", $sformatf(
            {"%s: payload changed during a stall - was data=%016h keep=%02h ",
             "last=%0b, now data=%016h keep=%02h last=%0b"},
            cfg.name_tag, held_data, held_keep, held_last,
            vif.mon_cb.tdata, vif.mon_cb.tkeep, vif.mon_cb.tlast))
        end
      end

      if (vif.mon_cb.tready !== 1'b1) begin
        held      = 1;
        held_data = vif.mon_cb.tdata;
        held_keep = vif.mon_cb.tkeep;
        held_last = vif.mon_cb.tlast;
        continue;
      end

      // ---- beat accepted ---------------------------------------------
      held = 0;
      if (!in_packet) begin
        in_packet = 1;
        t0        = $time;
      end

      if (cfg.enable_checks) begin
        if (!vif.keep_is_packed(vif.mon_cb.tkeep)) begin
          protocol_errors++;
          `uvm_error("AXIS/PROTO", $sformatf(
            "%s: tkeep=%02h is not a contiguous run from bit 0",
            cfg.name_tag, vif.mon_cb.tkeep))
        end
        if (vif.mon_cb.tkeep !== '1 && vif.mon_cb.tlast !== 1'b1) begin
          protocol_errors++;
          `uvm_error("AXIS/PROTO", $sformatf(
            "%s: partial tkeep=%02h on a non-final beat",
            cfg.name_tag, vif.mon_cb.tkeep))
        end
        if (vif.mon_cb.tkeep === '0) begin
          protocol_errors++;
          `uvm_error("AXIS/PROTO", $sformatf(
            "%s: null beat (tkeep=0) with tvalid asserted", cfg.name_tag))
        end
      end

      d_q.push_back(vif.mon_cb.tdata);
      k_q.push_back(vif.mon_cb.tkeep);
      u_q.push_back(vif.mon_cb.tuser);
      beats_seen++;

      publish_beat(vif.mon_cb.tdata, vif.mon_cb.tkeep, vif.mon_cb.tuser,
                   vif.mon_cb.tlast);

      if (vif.mon_cb.tlast === 1'b1) begin
        pkt = openpcie_axis_item::type_id::create("axis_pkt");
        pkt.data = new[d_q.size()];
        pkt.keep = new[k_q.size()];
        pkt.user = new[u_q.size()];
        foreach (pkt.data[i]) pkt.data[i] = d_q[i];
        foreach (pkt.keep[i]) pkt.keep[i] = k_q[i];
        foreach (pkt.user[i]) pkt.user[i] = u_q[i];
        pkt.pre_beat_delay = new[d_q.size()];
        pkt.t_start        = t0;
        pkt.t_end          = $time;
        pkt.beats_observed = d_q.size();

        packets_seen++;
        `uvm_info("AXIS/MON", $sformatf("%s: %s", cfg.name_tag,
                  pkt.convert2string()), UVM_HIGH)
        ap.write(pkt);

        d_q.delete(); k_q.delete(); u_q.delete();
        in_packet = 0;
      end
    end
  endtask

  local function void publish_beat(bit [AXIS_DATA_W-1:0] d,
                                   bit [AXIS_KEEP_W-1:0] k,
                                   bit [AXIS_USER_W-1:0] u,
                                   bit last);
    openpcie_axis_item b = openpcie_axis_item::type_id::create("axis_beat");
    b.data = new[1]; b.data[0] = d;
    b.keep = new[1]; b.keep[0] = k;
    b.user = new[1]; b.user[0] = u;
    b.pre_beat_delay = new[1];
    b.is_last        = last;
    b.beats_observed = 1;
    beat_ap.write(b);
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("AXIS/MON", $sformatf(
      "%s: %0d packet(s), %0d beat(s), %0d protocol error(s)",
      cfg.name_tag, packets_seen, beats_seen, protocol_errors), UVM_LOW)
  endfunction

endclass

`endif // OPENPCIE_AXIS_MONITOR_SVH
