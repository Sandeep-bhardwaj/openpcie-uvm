//---------------------------------------------------------------------------
// openpcie_ram_bkdr_if - backdoor into the SoC RAM for the firmware mailbox
//---------------------------------------------------------------------------
// The mailbox (tb/env/openpcie_fw_mailbox.svh) posts commands into the RAM of
// riscv_pcie_soc.  This interface gives it plain array accesses to that RAM,
// so nothing depends on uvm_hdl_deposit/uvm_hdl_read, on HDL write access
// being enabled at elaboration, or on the UVM HDL backdoor DPI (which xsim's
// bundled UVM compiles out).  The same code runs on xsim, VCS and Xcelium.
//
// The RAM arrives through a `ref` port and the interface is *bound* into
// riscv_pcie_soc (tb/top/openpcie_bind.sv), so the port connects to the DUT's own
// `ram`.  Why a ref port rather than a hierarchical reference: IEEE 1800-2017
// forbids using an interface as a *virtual* interface if its body contains a
// hierarchical reference to something outside itself.  Taking the array as a
// port keeps the body self-contained, so `virtual openpcie_ram_bkdr_if` is
// legal and the mailbox can hold one.
//
// Writes are ordinary assignments, not forces: the firmware stays free to
// write the same location afterwards, which it does when it clears CMD.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_RAM_BKDR_IF_SV
`define OPENPCIE_RAM_BKDR_IF_SV

// The bound `ram` is `logic [31:0] ram [0:2047]` (riscv_pcie_soc.sv:98); a ref
// port must match that type exactly, so the bound is spelled out rather than
// parameterised.  It is cross-checked against RAM_WORDS by scripts/check_tb.py.
interface openpcie_ram_bkdr_if (ref logic [31:0] mem [0:2047]);

  // Word-indexed, matching the DUT's own ram[mem_addr[12:2]] indexing.
  function automatic void wr_word(int unsigned idx, bit [31:0] value);
    mem[idx] = value;
  endfunction

  function automatic bit [31:0] rd_word(int unsigned idx);
    return mem[idx];
  endfunction

endinterface

`endif // OPENPCIE_RAM_BKDR_IF_SV
