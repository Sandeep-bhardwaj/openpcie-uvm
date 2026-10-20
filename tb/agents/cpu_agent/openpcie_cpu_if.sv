//---------------------------------------------------------------------------
// openPCIE UVM - PicoRV32 native memory-bus observation interface
//---------------------------------------------------------------------------
// Bound into `riscv_pcie_soc` (see openpcie_bind.sv) so the environment can
// watch every CPU access to the PCIe bridge without touching the RTL.
//
// This is the environment's *predictor input*: a firmware write to
// TX_DATA (0x3000000C) is what arms the transmit FSM, so the scoreboard
// reconstructs the expected TLP from this bus rather than trusting the
// sequence's intent.  That keeps the check independent of the stimulus path
// and means firmware bugs cannot mask RTL bugs.
//
// PicoRV32 native bus: `mem_valid` is held until `mem_ready` pulses; address,
// wdata and wstrb are stable across the whole transfer.  A transfer is a
// write when `mem_wstrb != 0`, a read otherwise.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_CPU_IF_SV
`define OPENPCIE_CPU_IF_SV

interface openpcie_cpu_if (
  input logic        clk,
  input logic        resetn,
  input logic        mem_valid,
  input logic        mem_ready,
  input logic [31:0] mem_addr,
  input logic [31:0] mem_wdata,
  input logic [3:0]  mem_wstrb,
  input logic [31:0] mem_rdata
);

  clocking mon_cb @(posedge clk);
    default input #1step;
    input mem_valid, mem_ready, mem_addr, mem_wdata, mem_wstrb, mem_rdata;
  endclocking

  modport mon (clocking mon_cb, input clk, resetn);

  // Address decode mirrored from riscv_pcie_soc.sv:80-81
  function automatic bit is_bridge(logic [31:0] a);
    return (a[31:24] == 8'h30);
  endfunction

  function automatic bit is_ram(logic [31:0] a);
    return (a[31:24] == 8'h00);
  endfunction

endinterface

`endif // OPENPCIE_CPU_IF_SV
