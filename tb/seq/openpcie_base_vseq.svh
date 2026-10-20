//---------------------------------------------------------------------------
// openpcie_base_vseq - common behaviour for every Tier 1 virtual sequence
//---------------------------------------------------------------------------
// Provides the firmware boot handshake, TLP construction helpers and the
// drain policy.  Derived sequences implement `body_main()` and inherit the
// bring-up and shutdown discipline.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_BASE_VSEQ_SVH
`define OPENPCIE_BASE_VSEQ_SVH

class openpcie_base_vseq extends uvm_sequence;

  `uvm_object_utils(openpcie_base_vseq)
  `uvm_declare_p_sequencer(openpcie_vseqr)

  // Cycles to let the DUT quiesce before the scoreboard's check_phase runs.
  // Two beats plus mailbox turnaround is plenty; make it generous so a slow
  // final packet is never mistaken for a missing one.
  int unsigned drain_cycles = 200;

  bit skip_boot = 0;

  function new(string name = "openpcie_base_vseq");
    super.new(name);
  endfunction

  //-----------------------------------------------------------------------
  // Objections are raised by openpcie_base_test::run_phase, not here.  The
  // sequence deliberately does not touch `starting_phase`: it was deprecated
  // between UVM 1.2 and 1800.2-2020, and having exactly one owner of the
  // objection is clearer than two overlapping ones.
  virtual task body();
    if (!skip_boot) boot();
    body_main();
    drain();
  endtask

  // Overridden by every real sequence.
  virtual task body_main();
    `uvm_warning(get_type_name(), "body_main() not overridden - doing nothing")
  endtask

  //-----------------------------------------------------------------------
  // Bring-up
  //-----------------------------------------------------------------------
  virtual task boot();
    if (p_sequencer.mbox == null)
      `uvm_fatal(get_type_name(), "virtual sequencer has no mailbox handle")
    p_sequencer.mbox.wait_for_boot();
    // One barrier command proves the command path works before the test
    // relies on it, so a broken mailbox fails here with a clear message
    // rather than as a downstream scoreboard mismatch.
    p_sequencer.mbox.sync();
  endtask

  virtual task drain();
    `uvm_info(get_type_name(), $sformatf("draining %0d cycles", drain_cycles),
              UVM_MEDIUM)
    p_sequencer.rst_vif.wait_cycles(drain_cycles);
  endtask

  //-----------------------------------------------------------------------
  // TLP helpers
  //-----------------------------------------------------------------------

  // Post a TLP through the firmware.  Only the 3 DW header form is reachable
  // at Tier 1 because the bridge's FSM emits exactly two beats.
  virtual task send_tlp(openpcie_tlp_pkg::openpcie_tlp t);
    bit [31:0] payload = (t.payload.size() > 0) ? t.payload[0] : 32'h0;

    if (t.hdr_dw() != 3)
      `uvm_fatal(get_type_name(), $sformatf(
        "Tier 1 bridge can only emit 3 DW headers; this TLP wants %0d DW",
        t.hdr_dw()))
    if (t.payload.size() > 1)
      `uvm_fatal(get_type_name(), $sformatf(
        "Tier 1 bridge carries at most one payload DW; this TLP has %0d",
        t.payload.size()))

    `uvm_info(get_type_name(), $sformatf("TX %s", t.convert2string()), UVM_MEDIUM)
    p_sequencer.mbox.send_tlp(t.dw0(), t.dw1(), t.dw2(), payload);
  endtask

  // Build a 32-bit memory write with a single payload DW.
  virtual function openpcie_tlp_pkg::openpcie_tlp make_memwr32(
      bit [31:0] addr, bit [31:0] data,
      bit [15:0] rid = 16'h0100, bit [7:0] tag = 8'h00);
    openpcie_tlp_pkg::openpcie_tlp t =
      openpcie_tlp_pkg::openpcie_tlp::type_id::create("memwr32");
    t.fmt          = openpcie_tlp_pkg::FMT_3DW_WD;
    t.ttype        = openpcie_tlp_pkg::TYPE_MEM;
    t.length       = 10'd1;
    t.requester_id = rid;
    t.tag          = tag;
    t.first_be     = 4'hF;
    t.last_be      = 4'h0;
    t.address      = {32'h0, addr};
    t.tc = '0; t.attr = '0; t.td = 0; t.ep = 0;
    t.payload = new[1];
    t.payload[0] = data;
    return t;
  endfunction

  // Build a 32-bit memory read (no payload).
  virtual function openpcie_tlp_pkg::openpcie_tlp make_memrd32(
      bit [31:0] addr, bit [15:0] rid = 16'h0100, bit [7:0] tag = 8'h00);
    openpcie_tlp_pkg::openpcie_tlp t =
      openpcie_tlp_pkg::openpcie_tlp::type_id::create("memrd32");
    t.fmt          = openpcie_tlp_pkg::FMT_3DW_ND;
    t.ttype        = openpcie_tlp_pkg::TYPE_MEM;
    t.length       = 10'd1;
    t.requester_id = rid;
    t.tag          = tag;
    t.first_be     = 4'hF;
    t.last_be      = 4'h0;
    t.address      = {32'h0, addr};
    t.tc = '0; t.attr = '0; t.td = 0; t.ep = 0;
    t.payload = new[0];
    return t;
  endfunction

  // Build a completion-with-data, the only inbound TLP the DUT's RX capture
  // FSM recognises (riscv_pcie_soc.sv:217).
  virtual function openpcie_tlp_pkg::openpcie_tlp make_cpld(
      bit [31:0] data,
      openpcie_tlp_pkg::cpl_status_e status = openpcie_tlp_pkg::CPL_SC,
      bit [15:0] cid = 16'h0200, bit [15:0] rid = 16'h0100,
      bit [7:0] tag = 8'h00, bit [6:0] lower_addr = 7'h0);
    openpcie_tlp_pkg::openpcie_tlp t =
      openpcie_tlp_pkg::openpcie_tlp::type_id::create("cpld");
    t.fmt          = openpcie_tlp_pkg::FMT_3DW_WD;
    t.ttype        = openpcie_tlp_pkg::TYPE_CPL;
    t.length       = 10'd1;
    t.completer_id = cid;
    t.requester_id = rid;
    t.cpl_status   = status;
    t.bcm          = 1'b0;
    t.byte_count   = 12'd4;
    t.tag          = tag;
    t.lower_addr   = lower_addr;
    t.tc = '0; t.attr = '0; t.td = 0; t.ep = 0;
    t.payload = new[1];
    t.payload[0] = data;
    return t;
  endfunction

  // Build a completion without data - what a real completer returns for UR,
  // CRS and CA.  3 DW header only, so it arrives as two beats with the final
  // tkeep = 0x0F.  The DUT's RX FSM still captures beat 1, whose upper half
  // is not part of the TLP; the predictor models that as written.
  virtual function openpcie_tlp_pkg::openpcie_tlp make_cpl(
      openpcie_tlp_pkg::cpl_status_e status = openpcie_tlp_pkg::CPL_UR,
      bit [15:0] cid = 16'h0200, bit [15:0] rid = 16'h0100,
      bit [7:0] tag = 8'h00, bit [6:0] lower_addr = 7'h0);
    openpcie_tlp_pkg::openpcie_tlp t = make_cpld(32'h0, status, cid, rid,
                                                 tag, lower_addr);
    t.set_name("cpl");
    t.fmt     = openpcie_tlp_pkg::FMT_3DW_ND;
    t.payload = new[0];
    return t;
  endfunction

  //-----------------------------------------------------------------------
  // RX injection
  //-----------------------------------------------------------------------
  virtual task inject_rx(openpcie_tlp_pkg::openpcie_tlp t,
                         int unsigned gap = 0);
    openpcie_axis_pkg::openpcie_axis_item it;
    bit [63:0] d[];
    bit [7:0]  k[];

    t.to_beats(d, k);

    it = openpcie_axis_pkg::openpcie_axis_item::type_id::create("rx_pkt");
    it.data = d;
    it.keep = k;
    it.user = new[d.size()];
    it.pre_beat_delay = new[d.size()];
    it.inter_packet_gap = gap;

    `uvm_info(get_type_name(), $sformatf("RX inject %s", t.convert2string()),
              UVM_MEDIUM)
    it.set_sequencer(p_sequencer.rx_seqr);
    start_item(it, -1, p_sequencer.rx_seqr);
    finish_item(it, -1);
  endtask

  //-----------------------------------------------------------------------
  // Register access through the firmware
  //-----------------------------------------------------------------------
  virtual task read_reg(bit [31:0] offset, output bit [31:0] value);
    p_sequencer.mbox.read_reg(offset, value);
  endtask

  // Raw bridge write - for offsets the RAL deliberately does not allow
  // writing (read-only registers), where the RTL's behaviour is under test.
  virtual task write_reg(bit [31:0] offset, bit [31:0] value);
    p_sequencer.mbox.write_reg(offset, value);
  endtask

  virtual task sync();
    p_sequencer.mbox.sync();
  endtask

endclass

`endif // OPENPCIE_BASE_VSEQ_SVH
