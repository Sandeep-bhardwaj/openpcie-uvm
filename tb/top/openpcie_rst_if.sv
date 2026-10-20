//---------------------------------------------------------------------------
// openpcie_rst_if - clock/reset control handed to the environment
//---------------------------------------------------------------------------
// Lets a sequence assert reset mid-traffic without reaching into tb_top.
// Reset here is the DUT's `resetn`, which the chip top drives as
// `~user_reset && user_lnk_up` (RC_direct_opensource.sv:126) - i.e. losing
// link-up looks exactly like a reset to the SoC, which is what the reset
// recovery test emulates.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_RST_IF_SV
`define OPENPCIE_RST_IF_SV

interface openpcie_rst_if (input logic clk);

  logic rst_n;

  // Number of clocks reset has been held low, for reporting.
  int unsigned resets_applied;

  task automatic assert_reset(int unsigned cycles = 10);
    rst_n = 1'b0;
    repeat (cycles) @(posedge clk);
    resets_applied++;
  endtask

  task automatic deassert_reset();
    @(posedge clk);
    rst_n = 1'b1;
  endtask

  task automatic pulse_reset(int unsigned cycles = 10);
    assert_reset(cycles);
    deassert_reset();
  endtask

  task automatic wait_cycles(int unsigned n);
    repeat (n) @(posedge clk);
  endtask

endinterface

`endif // OPENPCIE_RST_IF_SV
