//---------------------------------------------------------------------------
// openpcie_vseq_lib - Tier 1 virtual sequences
//---------------------------------------------------------------------------
// Each sequence maps to one or more vPlan items; the mapping is recorded in
// docs/testplan.md and repeated in the header comment of each class so the two
// cannot drift apart unnoticed.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_VSEQ_LIB_SVH
`define OPENPCIE_VSEQ_LIB_SVH

//---------------------------------------------------------------------------
// Smoke - the minimum that proves the whole path is alive.
// vPlan: SMOKE-001, TX-FMT-001
//---------------------------------------------------------------------------
class openpcie_smoke_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_smoke_vseq)

  function new(string name = "openpcie_smoke_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    openpcie_tlp_pkg::openpcie_tlp t;
    bit [31:0] v;

    // A single MemWr32 out.
    t = make_memwr32(32'h1000_0000, 32'hCAFE_BABE);
    send_tlp(t);
    sync();

    // Prove the status path answers at all.
    read_reg(REG_PHY_STATUS, v);
    `uvm_info(get_type_name(), $sformatf("PHY_STATUS = 0x%08h", v), UVM_LOW)
    read_reg(REG_ERR_STATUS, v);
    `uvm_info(get_type_name(), $sformatf("ERR_STATUS = 0x%08h", v), UVM_LOW)
  endtask
endclass


//---------------------------------------------------------------------------
// Directed TX shapes - walks the two tkeep outcomes the FSM can produce.
// vPlan: TX-FMT-001, TX-FMT-002, TX-DATA-001
//---------------------------------------------------------------------------
class openpcie_tx_directed_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_tx_directed_vseq)

  function new(string name = "openpcie_tx_directed_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    openpcie_tlp_pkg::openpcie_tlp t;

    // With payload -> final beat must be tkeep=0xFF (Fmt[1] set).
    send_tlp(make_memwr32(32'h0000_0000, 32'h0000_0000));
    send_tlp(make_memwr32(32'hFFFF_FFFC, 32'hFFFF_FFFF));
    send_tlp(make_memwr32(32'hDEAD_BEE0, 32'hA5A5_5A5A));

    // Without payload -> final beat must be tkeep=0x0F (Fmt[1] clear).
    send_tlp(make_memrd32(32'h1000_0000));
    send_tlp(make_memrd32(32'h8000_0004));

    // Completion outbound, exercising a different Type encoding.
    send_tlp(make_cpld(32'h1234_5678));

    // Walking-ones across the payload proves no bit is stuck in the
    // {tx_data, tx_header2} concatenation.
    for (int i = 0; i < 32; i++) begin
      t = make_memwr32(32'h2000_0000 + (i * 4), 32'h1 << i);
      send_tlp(t);
    end
    sync();
  endtask
endclass


//---------------------------------------------------------------------------
// Randomised TX traffic.
// vPlan: TX-RAND-001
//---------------------------------------------------------------------------
class openpcie_tx_random_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_tx_random_vseq)

  rand int unsigned n_tlps = 100;
  constraint c_n { n_tlps inside {[20:400]}; }

  function new(string name = "openpcie_tx_random_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    repeat (n_tlps) begin
      openpcie_tlp_pkg::openpcie_tlp t =
        openpcie_tlp_pkg::openpcie_tlp::type_id::create("rand_tlp");

      // Constrain to the shapes the Tier 1 FSM can actually emit: 3 DW
      // header, at most one payload DW.  A memory *read* carries no payload,
      // so its Length (the amount requested) is free up to 1024 DW; every
      // other request here is spec-limited to 1 DW.
      //
      // Kind and Length are chosen here and passed in as plain equalities.
      // Writing the Length rule as a constraint conditioned on fmt/ttype
      // (if/else or implication) hits an xsim 2026.1 solver defect: it never
      // produces the MEM + no-data combination at all, so Length never left
      // 1.  This form is equivalent and behaves the same on every solver.
      // c_tier1_shape is switched off because its soft Length is superseded.
      openpcie_tlp_pkg::tlp_fmt_e  k_fmt;
      openpcie_tlp_pkg::tlp_type_e k_type;
      bit [9:0]                    k_len = 10'd1;

      k_fmt = $urandom_range(1, 0) ? openpcie_tlp_pkg::FMT_3DW_WD
                                   : openpcie_tlp_pkg::FMT_3DW_ND;
      case ($urandom_range(4, 0))
        0       : k_type = openpcie_tlp_pkg::TYPE_IO;
        1       : k_type = openpcie_tlp_pkg::TYPE_CFG0;
        2       : k_type = openpcie_tlp_pkg::TYPE_CFG1;
        3       : k_type = openpcie_tlp_pkg::TYPE_CPL;
        default : k_type = openpcie_tlp_pkg::TYPE_MEM;
      endcase
      if (k_fmt == openpcie_tlp_pkg::FMT_3DW_ND &&
          k_type == openpcie_tlp_pkg::TYPE_MEM)
        case ($urandom_range(9, 0))
          0, 1, 2, 3 : k_len = 10'd1;
          4, 5       : k_len = 10'($urandom_range(8, 2));
          6, 7       : k_len = 10'($urandom_range(64, 9));
          8          : k_len = 10'($urandom_range(1023, 65));
          default    : k_len = 10'd0;            // 0 encodes 1024 DW
        endcase

      t.c_tier1_shape.constraint_mode(0);
      if (!t.randomize() with {
            fmt    == local::k_fmt;
            ttype  == local::k_type;
            length == local::k_len;
          })
        `uvm_fatal(get_type_name(), "TLP randomize failed")

      send_tlp(t);
    end
    sync();
  endtask
endclass


//---------------------------------------------------------------------------
// TX under backpressure.
//
// This is the sequence that targets the transmit FSM's early tready sampling:
// riscv_pcie_soc.sv:195-211 evaluates s_axis_tx_tready in the same cycle it
// schedules tvalid, so the state advances one cycle before the beat it
// describes is actually presented.  With an always-ready sink the two errors
// cancel; with a stalling sink beat 0 can be overwritten by beat 1 before it
// was ever accepted.  The AXIS monitor's stability check and the scoreboard's
// packet compare are both positioned to catch that.
//
// The responder's ready_mode is set by the *test*, not here, so the same
// sequence can be reused across backpressure profiles.
// vPlan: TX-PROTO-004, TX-FLOW-001
//---------------------------------------------------------------------------
class openpcie_tx_backpressure_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_tx_backpressure_vseq)

  rand int unsigned n_tlps = 60;
  constraint c_n { n_tlps inside {[30:200]}; }

  function new(string name = "openpcie_tx_backpressure_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    for (int i = 0; i < n_tlps; i++) begin
      // Alternate payload/no-payload so both final-beat tkeep values are
      // presented while the sink is stalling.
      if (i % 2 == 0) send_tlp(make_memwr32(32'h4000_0000 + i*4, ~i));
      else            send_tlp(make_memrd32(32'h4000_0000 + i*4));
    end
    sync();
  endtask
endclass


//---------------------------------------------------------------------------
// RX completion capture.
//
// Injects CplD TLPs and reads back the three capture registers through the
// firmware.  Also covers the DUT's phase FSM having no packet-boundary
// resynchronisation: a non-completion TLP arriving in phase 0 is ignored
// entirely (riscv_pcie_soc.sv:215-229), which the predictor mirrors.
// vPlan: RX-CAP-001, RX-CAP-002, RX-CAP-003
//---------------------------------------------------------------------------
class openpcie_rx_cpl_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_rx_cpl_vseq)

  rand int unsigned n_cpl = 30;
  constraint c_n { n_cpl inside {[10:100]}; }

  // A test with no TX traffic must tell the scoreboard so, or the
  // end-of-test activity check fires.
  function new(string name = "openpcie_rx_cpl_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    bit [31:0] st, dat, hdr;

    for (int i = 0; i < n_cpl; i++) begin
      openpcie_tlp_pkg::openpcie_tlp c;
      openpcie_tlp_pkg::cpl_status_e s;

      s = (i % 4 == 0) ? openpcie_tlp_pkg::CPL_SC  :
          (i % 4 == 1) ? openpcie_tlp_pkg::CPL_UR  :
          (i % 4 == 2) ? openpcie_tlp_pkg::CPL_CRS :
                         openpcie_tlp_pkg::CPL_CA;

      c = make_cpld(.data(32'hC0DE_0000 | i), .status(s), .tag(i[7:0]));
      inject_rx(c, .gap($urandom_range(6, 0)));

      // Let the capture registers settle, then read all three back.  The
      // scoreboard compares each against the predictor.
      sync();
      read_reg(REG_RX_STATUS,   st);
      read_reg(REG_RX_DATA,     dat);
      read_reg(REG_RX_HDR_INFO, hdr);

      `uvm_info(get_type_name(), $sformatf(
        "cpl[%0d] status=%s -> RX_STATUS=%08h RX_DATA=%08h RX_HDR=%08h",
        i, s.name(), st, dat, hdr), UVM_HIGH)
    end

    // Completions without data - how UR, CRS and CA actually arrive.  Two
    // beats, final tkeep 0x0F.  RX_STATUS must pick up the status; RX_DATA
    // takes beat 1's upper half, which is outside the TLP (see make_cpl).
    for (int i = 0; i < 4; i++) begin
      openpcie_tlp_pkg::cpl_status_e s =
          (i == 0) ? openpcie_tlp_pkg::CPL_UR  :
          (i == 1) ? openpcie_tlp_pkg::CPL_CRS :
          (i == 2) ? openpcie_tlp_pkg::CPL_CA  :
                     openpcie_tlp_pkg::CPL_SC;
      inject_rx(make_cpl(.status(s), .tag(8'h80 | i)), .gap($urandom_range(6, 0)));
      sync();
      read_reg(REG_RX_STATUS,   st);
      read_reg(REG_RX_HDR_INFO, hdr);
    end

    // Now a non-completion inbound TLP: the DUT should ignore it in phase 0.
    // If the capture registers move, the RX filter is broken.
    begin
      openpcie_tlp_pkg::openpcie_tlp m = make_memwr32(32'h9999_0000, 32'hBAD0_BAD0);
      inject_rx(m);
      sync();
      read_reg(REG_RX_DATA, dat);
      `uvm_info(get_type_name(), $sformatf(
        "after non-completion inbound, RX_DATA=%08h (must be unchanged)", dat),
        UVM_LOW)
    end
  endtask
endclass


//---------------------------------------------------------------------------
// Register access via RAL.
//
// Uses the firmware frontdoor.  Deliberately does NOT run
// uvm_reg_bit_bash_seq against the TX registers: they are write-only holes
// that read back 0, so bit-bash would report false failures on correct RTL.
// vPlan: REG-001, REG-002, REG-003
//---------------------------------------------------------------------------
class openpcie_reg_access_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_reg_access_vseq)

  function new(string name = "openpcie_reg_access_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    uvm_status_e   status;
    uvm_reg_data_t val;

    if (p_sequencer.ral == null) begin
      `uvm_warning(get_type_name(), "no RAL built - skipping register test")
      return;
    end

    // Read every readable register through the RAL frontdoor.
    p_sequencer.ral.RX_STATUS  .read(status, val, .parent(this));
    p_sequencer.ral.RX_DATA    .read(status, val, .parent(this));
    p_sequencer.ral.RX_HDR_INFO.read(status, val, .parent(this));
    p_sequencer.ral.ERR_STATUS .read(status, val, .parent(this));
    p_sequencer.ral.PHY_STATUS .read(status, val, .parent(this));

    // Write the header registers, then confirm they are genuinely write-only
    // by reading them back and expecting 0 (the RTL's read-case default).
    // HDR0 is a well-formed 3 DW MWr header so the packet this test sends
    // does not register as a stray 4 DW / Length-0 shape in TLP coverage.
    p_sequencer.ral.TX_HDR0.write(status, 32'h4000_0001, .parent(this));
    p_sequencer.ral.TX_HDR1.write(status, 32'hBBBB_110F, .parent(this));
    p_sequencer.ral.TX_HDR2.write(status, 32'hCCCC_2220, .parent(this));

    begin
      bit [31:0] rb;
      bit [31:0] wo[4] = '{REG_TX_HDR0, REG_TX_HDR1, REG_TX_HDR2, REG_TX_DATA};
      foreach (wo[i]) begin
        read_reg(wo[i], rb);
        if (rb !== 32'h0)
          `uvm_error(get_type_name(), $sformatf(
            "+0x%02h is documented write-only and should read 0, got %08h",
            wo[i], rb))
      end
    end

    // Writes to the read-only registers.  +0x10..+0x1C have no write arm in
    // the RTL and must change nothing; the scoreboard's readback compare
    // proves it.  PHY_STATUS (+0x20) is different: the write decode ignores
    // mem_addr[5], so this write lands on TX_HDR0 (vPlan REG-004).  The value
    // is a 3 DW MRd header, and it is deliberately left in place: the packet
    // armed below then goes out as a MRd (final tkeep 0x0F) instead of the
    // MWr written through the RAL.  The predictor decodes writes like the
    // RTL, so the scoreboard's packet compare is what proves the alias.
    // With the RTL fixes applied (OPENPCIE_RTL_FIXES, RTL-FIX-002) the write
    // is ignored and the MWr goes out; the same compare then proves the fix.
    write_reg(REG_RX_STATUS,   32'hFFFF_FFFF);
    write_reg(REG_RX_DATA,     32'hFFFF_FFFF);
    write_reg(REG_RX_HDR_INFO, 32'hFFFF_FFFF);
    write_reg(REG_ERR_STATUS,  32'hFFFF_FFFF);
    write_reg(REG_PHY_STATUS,  32'h0000_0001);
    p_sequencer.ral.RX_STATUS  .read(status, val, .parent(this));
    p_sequencer.ral.RX_DATA    .read(status, val, .parent(this));
    p_sequencer.ral.RX_HDR_INFO.read(status, val, .parent(this));
    p_sequencer.ral.ERR_STATUS .read(status, val, .parent(this));
    p_sequencer.ral.PHY_STATUS .read(status, val, .parent(this));

    // Now arm the transmit: the headers written above plus this payload must
    // appear on the stream exactly as the predictor computed them.
    p_sequencer.ral.TX_DATA.write(status, 32'hDDDD_3333, .parent(this));
    sync();

    // 64-byte decode aliasing: +0x54 must mirror RX_DATA at +0x14.
    begin
      bit [31:0] a, b;
      read_reg(REG_RX_DATA, a);
      read_reg(32'h54,      b);
      if (a !== b)
        `uvm_error(get_type_name(), $sformatf(
          "expected +0x54 to alias RX_DATA (+0x14): %08h vs %08h", b, a))
    end
  endtask
endclass


//---------------------------------------------------------------------------
// Sideband movement while traffic runs.
// vPlan: CFG-001, CFG-002, TX-FLOW-001
//---------------------------------------------------------------------------
class openpcie_sideband_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_sideband_vseq)

  function new(string name = "openpcie_sideband_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    openpcie_cfg_pkg::openpcie_cfg_static_seq cs;
    bit [31:0] v;

    // Sweep tx_buf_av down to zero.  The DUT never consults it before
    // transmitting, so traffic must continue - covering credit exhaustion
    // documents that the condition was really presented.
    // The last few credits are stepped one at a time: 1..3 is where a flow
    // control bug would bite, and the coarse sweep used to jump from 8 to 0.
    // cfg_status alternates through all-zeros and all-ones along the way.
    int unsigned credits[] = '{32, 24, 16, 8, 3, 2, 1, 0};
    foreach_credit: foreach (credits[i]) begin
      int unsigned c = credits[i];
      cs = openpcie_cfg_pkg::openpcie_cfg_static_seq::type_id::create("cs");
      if (!cs.randomize() with {
            cfg_status  == ((i % 3 == 0) ? 16'h0000 :
                            (i % 3 == 1) ? 16'hFFFF : 16'h0010);
            cfg_command == 16'h0006;
            tx_buf_av   == c[5:0];
            err_fatal   == 1'b0;
          }) `uvm_fatal(get_type_name(), "cfg randomize failed")
      cs.start(p_sequencer.cfg_seqr);

      send_tlp(make_memwr32(32'h5000_0000 + c, c));
      sync();
      read_reg(REG_PHY_STATUS, v);
      if (v[5:0] !== c[5:0])
        `uvm_error(get_type_name(), $sformatf(
          "PHY_STATUS tx_buf_av readback %0d, driven %0d", v[5:0], c[5:0]))
    end

    // Error-fatal assertion must appear in ERR_STATUS bit 16.
    cs = openpcie_cfg_pkg::openpcie_cfg_static_seq::type_id::create("cs_err");
    if (!cs.randomize() with {
          cfg_status  == 16'hA5A5;
          cfg_command == 16'h0146;
          tx_buf_av   == 6'd32;
          err_fatal   == 1'b1;
        }) `uvm_fatal(get_type_name(), "cfg randomize failed")
    cs.start(p_sequencer.cfg_seqr);

    sync();
    read_reg(REG_ERR_STATUS, v);
    if (v[15:0] !== 16'hA5A5 || v[16] !== 1'b1)
      `uvm_error(get_type_name(), $sformatf(
        "ERR_STATUS = %08h, expected cfg_status=A5A5 and err_fatal=1", v))

    send_tlp(make_memwr32(32'h6000_0000, 32'hE12A_0001));
    sync();

    // err_fatal while credits are low or exhausted - the combination a real
    // link failure produces.  ERR_STATUS and PHY_STATUS must both follow.
    foreach (credits[i]) begin
      if (credits[i] > 16) continue;
      cs = openpcie_cfg_pkg::openpcie_cfg_static_seq::type_id::create("cs_err_lo");
      if (!cs.randomize() with {
            cfg_status  == 16'hFFFF;
            cfg_command == 16'h0146;
            tx_buf_av   == credits[i][5:0];
            err_fatal   == 1'b1;
          }) `uvm_fatal(get_type_name(), "cfg randomize failed")
      cs.start(p_sequencer.cfg_seqr);
      sync();
      read_reg(REG_ERR_STATUS, v);
      if (v[16] !== 1'b1)
        `uvm_error(get_type_name(), $sformatf(
          "ERR_STATUS = %08h with err_fatal driven at tx_buf_av=%0d",
          v, credits[i]))
    end
  endtask
endclass


//---------------------------------------------------------------------------
// Reset recovery.
//
// The chip top drives the SoC's resetn as (~user_reset && user_lnk_up)
// (RC_direct_opensource.sv:126), so a link-down looks exactly like a reset.
// After reset the CPU restarts from PROGADDR_RESET and the mailbox must
// re-boot; anything the DUT had latched must be gone.
// vPlan: RST-001, RST-002
//---------------------------------------------------------------------------
class openpcie_reset_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_reset_vseq)

  function new(string name = "openpcie_reset_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    bit [31:0] v;

    // Traffic before the reset.
    repeat (8) send_tlp(make_memwr32(32'h7000_0000, 32'h1111_2222));
    sync();

    // Yank reset mid-flight.
    `uvm_info(get_type_name(), "asserting reset", UVM_LOW)
    p_sequencer.rst_vif.pulse_reset(20);

    // The CPU restarts; wait for the boot magic again.  This also proves the
    // firmware image survived reset (it lives in the same RAM array).
    p_sequencer.mbox.wait_for_boot();
    sync();

    // RX capture registers must have been cleared by reset
    // (riscv_pcie_soc.sv:157-167).
    read_reg(REG_RX_DATA, v);
    if (v !== 32'h0)
      `uvm_error(get_type_name(), $sformatf(
        "RX_DATA = %08h after reset, expected 0", v))
    read_reg(REG_RX_STATUS, v);
    if (v !== 32'h0)
      `uvm_error(get_type_name(), $sformatf(
        "RX_STATUS = %08h after reset, expected 0", v))

    // And the datapath must still work afterwards.
    repeat (8) send_tlp(make_memwr32(32'h7100_0000, 32'h3333_4444));
    sync();
  endtask
endclass


//---------------------------------------------------------------------------
// Mixed random traffic - the regression workhorse.
// vPlan: MIX-001
//---------------------------------------------------------------------------
class openpcie_random_vseq extends openpcie_base_vseq;
  `uvm_object_utils(openpcie_random_vseq)

  rand int unsigned n_iter = 150;
  constraint c_n { n_iter inside {[50:500]}; }

  function new(string name = "openpcie_random_vseq");
    super.new(name);
  endfunction

  virtual task body_main();
    for (int i = 0; i < n_iter; i++) begin
      case ($urandom_range(9, 0))
        0, 1, 2, 3 : send_tlp(make_memwr32($urandom & 32'hFFFF_FFFC, $urandom));
        4, 5       : send_tlp(make_memrd32($urandom & 32'hFFFF_FFFC));
        6          : send_tlp(make_cpld($urandom));
        7          : begin
                       inject_rx(make_cpld(.data($urandom),
                                           .tag($urandom_range(255, 0))),
                                 $urandom_range(4, 0));
                       sync();
                     end
        8          : begin
                       bit [31:0] v;
                       read_reg(32'h10 + (($urandom_range(3, 0)) * 4), v);
                     end
        9          : begin
                       openpcie_cfg_pkg::openpcie_cfg_random_seq rs =
                         openpcie_cfg_pkg::openpcie_cfg_random_seq
                           ::type_id::create("rs");
                       if (!rs.randomize() with { n_changes inside {[1:3]}; })
                         `uvm_fatal(get_type_name(), "cfg randomize failed")
                       rs.start(p_sequencer.cfg_seqr);
                     end
        default    : `uvm_fatal(get_type_name(), "unreachable traffic choice")
      endcase
    end
    sync();
  endtask
endclass

`endif // OPENPCIE_VSEQ_LIB_SVH
