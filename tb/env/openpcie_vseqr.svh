//---------------------------------------------------------------------------
// openpcie_vseqr - virtual sequencer for the Tier 1 environment
//---------------------------------------------------------------------------
// Carries the three ways a sequence can reach the DUT:
//   rx_seqr   inject AXI4-Stream packets into m_axis_rx_*
//   cfg_seqr  move the configuration/status sidebands
//   mbox      run firmware commands (the only path to the bridge registers)
// plus the RAL handle and reset control.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_VSEQR_SVH
`define OPENPCIE_VSEQR_SVH

class openpcie_vseqr extends uvm_sequencer;

  `uvm_component_utils(openpcie_vseqr)

  openpcie_axis_pkg::openpcie_axis_sequencer rx_seqr;
  openpcie_cfg_pkg::openpcie_cfg_sequencer   cfg_seqr;

  openpcie_fw_mailbox      mbox;
  openpcie_reg_block       ral;
  openpcie_env_cfg         cfg;
  virtual openpcie_rst_if  rst_vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass

`endif // OPENPCIE_VSEQR_SVH
