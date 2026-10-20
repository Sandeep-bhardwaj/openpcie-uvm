//---------------------------------------------------------------------------
// openpcie_predictor - reference model of the riscv_pcie_soc bridge
//---------------------------------------------------------------------------
// Inputs
//   * CPU bus items (from the bound cpu_if) - what the firmware actually did
//   * RX beats       (from the RX AXIS monitor) - what the TB injected
//   * cfg sideband snapshots
//
// Outputs
//   * expected TX packets, published to the scoreboard
//   * expected status-register values, queried by the scoreboard when it sees
//     the firmware read one back
//
// Deriving expectations from the CPU bus rather than from sequence intent is
// deliberate: it means a firmware defect shows up as a mismatch instead of
// silently changing both the stimulus and the expectation.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_PREDICTOR_SVH
`define OPENPCIE_PREDICTOR_SVH

`uvm_analysis_imp_decl(_cpu)
`uvm_analysis_imp_decl(_rxbeat)
`uvm_analysis_imp_decl(_cfg)

class openpcie_predictor extends uvm_component;

  `uvm_component_utils(openpcie_predictor)

  uvm_analysis_imp_cpu    #(openpcie_cpu_pkg::openpcie_cpu_item, openpcie_predictor) cpu_imp;
  uvm_analysis_imp_rxbeat #(openpcie_axis_pkg::openpcie_axis_item, openpcie_predictor) rx_imp;
  uvm_analysis_imp_cfg    #(openpcie_cfg_pkg::openpcie_cfg_item, openpcie_predictor) cfg_imp;

  uvm_analysis_port #(openpcie_axis_pkg::openpcie_axis_item) exp_tx_ap;

  // ---- shadow of the DUT's TX header registers -------------------------
  protected bit [31:0] m_tx_hdr [3];
  protected bit        m_tx_hdr_written [3];

  // ---- shadow of the DUT's RX capture registers ------------------------
  // Mirrors riscv_pcie_soc.sv:215-229 exactly, including the two-phase
  // state machine and its lack of any sof/tkeep qualification.
  protected bit        m_rx_phase;
  protected bit [31:0] m_rx_status;
  protected bit [31:0] m_rx_data;
  protected bit [31:0] m_rx_hdr_info;

  // ---- shadow of the sidebands -----------------------------------------
  protected bit [15:0] m_cfg_status;
  protected bit        m_err_fatal;
  protected bit [5:0]  m_tx_buf_av;
  protected time       m_cfg_last_change;

  // Status registers are registered one cycle behind their inputs
  // (riscv_pcie_soc.sv:147-155).  A readback is only checked strictly when the
  // sideband has been stable for longer than this, otherwise the comparison
  // would race the pipeline.
  int unsigned settle_ns = 100;

  int unsigned predicted_tx_packets;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cpu_imp   = new("cpu_imp",   this);
    rx_imp    = new("rx_imp",    this);
    cfg_imp   = new("cfg_imp",   this);
    exp_tx_ap = new("exp_tx_ap", this);
  endfunction

  //-----------------------------------------------------------------------
  // CPU bus - drives TX prediction
  //-----------------------------------------------------------------------
  virtual function void write_cpu(openpcie_cpu_pkg::openpcie_cpu_item t);
    if (!t.to_bridge) return;

    // The RTL's write decode uses mem_addr[4:2] only (riscv_pcie_soc.sv:175),
    // while its read decode also uses mem_addr[5].  So writes to +0x20..+0x2C
    // - PHY_STATUS and the three words above it - land on the TX registers,
    // and a write to +0x2C starts a transmit.  Decode the same way; vPlan
    // REG-004 records it.  Writes to +0x10..+0x1C really are ignored.
    //
    // OPENPCIE_RTL_FIXES is defined by every runner that compiles the RTL
    // with rtl_patches.py --with-fixes, whose RTL-FIX-002 adds !mem_addr[5]
    // to the write enable; the model follows it.
    if (t.dir == openpcie_cpu_pkg::CPU_WRITE) begin
`ifdef OPENPCIE_RTL_FIXES
      if (!t.bridge_offset[5])
`endif
      case (t.bridge_offset[4:2])
        3'd0    : begin m_tx_hdr[0] = t.wdata; m_tx_hdr_written[0] = 1; end
        3'd1    : begin m_tx_hdr[1] = t.wdata; m_tx_hdr_written[1] = 1; end
        3'd2    : begin m_tx_hdr[2] = t.wdata; m_tx_hdr_written[2] = 1; end
        3'd3    : predict_tx(t.wdata);
        default : /* +0x10..+0x1C: read-only, ignored by the RTL */ ;
      endcase
    end
  endfunction

  // A write to TX_DATA arms the transmit FSM.  The resulting packet is fully
  // determined by the three header registers plus the payload DW:
  //   beat0 = {HDR1, HDR0}          tkeep = 0xFF  tlast = 0
  //   beat1 = {DATA, HDR2}          tkeep = HDR0[30] ? 0xFF : 0x0F   tlast = 1
  // HDR0 bit 30 is TLP Fmt[1], the "has payload" bit (riscv_pcie_soc.sv:204).
  protected virtual function void predict_tx(bit [31:0] payload);
    openpcie_axis_pkg::openpcie_axis_item exp;

    if (!(m_tx_hdr_written[0] && m_tx_hdr_written[1] && m_tx_hdr_written[2]))
      `uvm_warning("PRED", $sformatf(
        {"TX_DATA written before all three header registers were ",
         "initialised (written flags = %0b%0b%0b); the DUT will transmit ",
         "stale header contents"},
        m_tx_hdr_written[2], m_tx_hdr_written[1], m_tx_hdr_written[0]))

    exp = openpcie_axis_pkg::openpcie_axis_item::type_id::create("exp_tx");
    exp.data = new[2];
    exp.keep = new[2];
    exp.user = new[2];
    exp.pre_beat_delay = new[2];

    exp.data[0] = {m_tx_hdr[1], m_tx_hdr[0]};
    exp.keep[0] = 8'hFF;
    exp.data[1] = {payload,     m_tx_hdr[2]};
    exp.keep[1] = m_tx_hdr[0][30] ? 8'hFF : 8'h0F;

    predicted_tx_packets++;
    `uvm_info("PRED", $sformatf(
      "expect TX packet #%0d: [0]=%016h/%02h [1]=%016h/%02h",
      predicted_tx_packets, exp.data[0], exp.keep[0], exp.data[1], exp.keep[1]),
      UVM_MEDIUM)

    exp_tx_ap.write(exp);
  endfunction

  //-----------------------------------------------------------------------
  // RX beats - drives status-register prediction
  //-----------------------------------------------------------------------
  // Reproduces riscv_pcie_soc.sv:215-229.  Note what the RTL does *not* do:
  // it never checks tkeep and never resynchronises on packet boundaries, so a
  // non-completion TLP arriving in phase 0 leaves the FSM stuck.  The model
  // reproduces that faithfully so the scoreboard measures the RTL as written,
  // and vplan item RX-CAP-003 records it as a design limitation.
  virtual function void write_rxbeat(openpcie_axis_pkg::openpcie_axis_item b);
    bit [63:0] d = b.data[0];

    if (m_rx_phase == 1'b0) begin
      if (d[28:24] == 5'b01010) begin          // TLP Type == Completion
        m_rx_status = {29'b0, d[47:45]};       // DW1[15:13] == cpl status
        m_rx_phase  = 1'b1;
      end
    end
    else begin
      m_rx_hdr_info = d[31:0];                 // DW2
      m_rx_data     = d[63:32];                // DW3 == payload
      if (b.is_last) m_rx_phase = 1'b0;
    end
  endfunction

  //-----------------------------------------------------------------------
  // Sidebands
  //-----------------------------------------------------------------------
  virtual function void write_cfg(openpcie_cfg_pkg::openpcie_cfg_item c);
    m_cfg_status      = c.cfg_status;
    m_err_fatal       = c.err_fatal;
    m_tx_buf_av       = c.tx_buf_av;
    m_cfg_last_change = $time;
  endfunction

  //-----------------------------------------------------------------------
  // Queries used by the scoreboard on a firmware readback
  //-----------------------------------------------------------------------
  function bit sidebands_settled();
    return ($time - m_cfg_last_change) > settle_ns;
  endfunction

  // Returns 1 and sets `exp` when the offset is predictable; returns 0 for
  // offsets whose value the environment cannot pin down (currently only
  // PHY_STATUS's tx_state field, which is internal and transient).
  function bit expected_read(bit [31:0] offset, output bit [31:0] exp,
                             output bit [31:0] mask);
    mask = 32'hFFFF_FFFF;
    case (offset)
      REG_RX_STATUS   : begin exp = m_rx_status;   return 1; end
      REG_RX_DATA     : begin exp = m_rx_data;     return 1; end
      REG_RX_HDR_INFO : begin exp = m_rx_hdr_info; return 1; end
      REG_ERR_STATUS  : begin
                          exp  = {15'b0, m_err_fatal, m_cfg_status};
                          return sidebands_settled();
                        end
      REG_PHY_STATUS  : begin
                          // Only tx_buf_av[5:0] is externally determined;
                          // tx_state[7:6] depends on where the FSM happens to
                          // be, so it is masked out of the comparison.
                          exp  = {26'b0, 2'b00, m_tx_buf_av};
                          mask = 32'h0000_003F;
                          return sidebands_settled();
                        end
      // Write-only holes: the RTL's read case has no arm for 0x00..0x0C, so
      // they return 0.
      REG_TX_HDR0, REG_TX_HDR1, REG_TX_HDR2, REG_TX_DATA :
                        begin exp = 32'h0; return 1; end
      default         : begin exp = 32'h0; return 0; end
    endcase
  endfunction

  //-----------------------------------------------------------------------
  virtual function void reset();
    m_rx_phase    = 1'b0;
    m_rx_status   = '0;
    m_rx_data     = '0;
    m_rx_hdr_info = '0;
    foreach (m_tx_hdr_written[i]) m_tx_hdr_written[i] = 0;
  endfunction

endclass

`endif // OPENPCIE_PREDICTOR_SVH
