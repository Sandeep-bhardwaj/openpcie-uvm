//---------------------------------------------------------------------------
// openpcie_bind - non-intrusive attachment of TB structure into the DUT
//---------------------------------------------------------------------------
// The openPCIE RTL is never edited.  Everything the environment
// needs from inside `riscv_pcie_soc` arrives through these three binds:
//
//   u_cpu_if   observation interface on the PicoRV32 native memory bus,
//              consumed by openpcie_cpu_agent and, through it, the predictor
//   u_bkdr     RAM backdoor used by the firmware mailbox
//   u_soc_sva  white-box assertions on the transmit FSM, receive phase and
//              CPU handshake
//
// The interfaces are reached from tb_top by hierarchical name
// (tb_top.dut.u_cpu_if, tb_top.dut.u_bkdr), which is how the virtual
// interfaces get into the config DB without an interface needing to publish
// itself.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_BIND_SV
`define OPENPCIE_BIND_SV

// Defined here rather than in tb_top because this file is compiled first.
// Override from the command line with +define+OPENPCIE_SOC_SVA_ENABLE=0 to
// drop the white-box assertions during first bring-up.
`ifndef OPENPCIE_SOC_SVA_ENABLE
  `define OPENPCIE_SOC_SVA_ENABLE 1
`endif

bind riscv_pcie_soc openpcie_cpu_if u_cpu_if (
  .clk       (clk),
  .resetn    (resetn),
  .mem_valid (mem_valid),
  .mem_ready (mem_ready),
  .mem_addr  (mem_addr),
  .mem_wdata (mem_wdata),
  .mem_wstrb (mem_wstrb),
  .mem_rdata (mem_rdata)
);

// The ref port aliases the DUT's own RAM array; see openpcie_ram_bkdr_if.sv.
bind riscv_pcie_soc openpcie_ram_bkdr_if u_bkdr (.mem(ram));

bind riscv_pcie_soc openpcie_soc_sva #(
  .ENABLE (`OPENPCIE_SOC_SVA_ENABLE)
) u_soc_sva (
  .clk              (clk),
  .resetn           (resetn),

  .mem_valid        (mem_valid),
  .mem_ready        (mem_ready),
  .mem_addr         (mem_addr),
  .mem_wdata        (mem_wdata),
  .mem_wstrb        (mem_wstrb),

  .s_axis_tx_tdata  (s_axis_tx_tdata),
  .s_axis_tx_tkeep  (s_axis_tx_tkeep),
  .s_axis_tx_tlast  (s_axis_tx_tlast),
  .s_axis_tx_tvalid (s_axis_tx_tvalid),
  .s_axis_tx_tready (s_axis_tx_tready),

  .m_axis_rx_tvalid (m_axis_rx_tvalid),
  .m_axis_rx_tready (m_axis_rx_tready),

  .tx_buf_av        (tx_buf_av),
  .cfg_status       (cfg_status),
  .cfg_command      (cfg_command),

  .tx_state         (tx_state),
  .rx_phase         (rx_phase)
);

`endif // OPENPCIE_BIND_SV
