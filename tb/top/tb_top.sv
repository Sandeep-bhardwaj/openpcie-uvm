//---------------------------------------------------------------------------
// tb_top - Tier 1 testbench top (DUT = riscv_pcie_soc)
//---------------------------------------------------------------------------
// Responsibilities, and nothing beyond them:
//   * generate clock and reset
//   * instantiate the DUT and the three interfaces
//   * instantiate the AXI4-Stream assertion checkers
//   * publish virtual interfaces into the config DB
//   * run_test()
//
// All policy lives in the test library.  The DUT's own
// $readmemh("firmware.hex", ram) is what loads the program, so the run
// directory must contain firmware.hex - the Makefile copies it in and the
// initial block below fails loudly if it is missing.
//---------------------------------------------------------------------------

// OPENPCIE_SOC_SVA_ENABLE is defined in tb/top/openpcie_bind.sv, which the
// filelist compiles before this file.

`timescale 1ns / 1ps

module tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import openpcie_types_pkg::*;
  import openpcie_env_pkg::*;
  import openpcie_test_pkg::*;

  //-----------------------------------------------------------------------
  // Clock and reset
  //-----------------------------------------------------------------------
  // 62.5 MHz: user_clk for a x1 Gen2 link is 250 MHz / 4 with a 64-bit
  // datapath (PCIE_LANES=1, PCIE_GEN=2 in link_pkg.sv:42-43).
  localparam realtime CLK_PERIOD = 16ns;

  logic clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  openpcie_rst_if rst_if (.clk(clk));

  wire resetn = rst_if.rst_n;

  initial begin
    rst_if.rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_if.rst_n = 1'b1;
  end

  //-----------------------------------------------------------------------
  // Interfaces
  //-----------------------------------------------------------------------
  openpcie_axis_if #(.DATA_W(AXIS_DATA_W), .USER_W(AXIS_USER_W))
                   rx_if (.clk(clk), .rst_n(resetn));
  openpcie_axis_if #(.DATA_W(AXIS_DATA_W), .USER_W(AXIS_USER_W))
                   tx_if (.clk(clk), .rst_n(resetn));
  openpcie_cfg_if  cfg_if(.clk(clk), .rst_n(resetn));

  //-----------------------------------------------------------------------
  // DUT
  //-----------------------------------------------------------------------
  // Note s_axis_tx_* is a DUT *output* group and m_axis_rx_* a DUT *input*
  // group, so tx_if is driven by the DUT and rx_if by the testbench.
  riscv_pcie_soc dut (
    .clk                        (clk),
    .resetn                     (resetn),

    .s_axis_tx_tdata            (tx_if.tdata),
    .s_axis_tx_tkeep            (tx_if.tkeep),
    .s_axis_tx_tlast            (tx_if.tlast),
    .s_axis_tx_tvalid           (tx_if.tvalid),
    .s_axis_tx_tready           (tx_if.tready),

    .m_axis_rx_tdata            (rx_if.tdata),
    .m_axis_rx_tkeep            (rx_if.tkeep),
    .m_axis_rx_tlast            (rx_if.tlast),
    .m_axis_rx_tvalid           (rx_if.tvalid),
    .m_axis_rx_tready           (rx_if.tready),

    .cfg_status                 (cfg_if.cfg_status),
    .cfg_command                (cfg_if.cfg_command),
    .cfg_msg_received_err_fatal (cfg_if.cfg_msg_received_err_fatal),

    .tx_buf_av                  (cfg_if.tx_buf_av)
  );

  // The DUT does not drive tuser on either port (it has no such pins), so tie
  // the interface fields off rather than leaving them floating into the SVA.
  assign tx_if.tuser = '0;

  //-----------------------------------------------------------------------
  // Protocol checkers
  //-----------------------------------------------------------------------
  // Instantiated rather than bound: binding into an interface instance is
  // supported unevenly across simulators, and this connection is explicit.
  openpcie_axis_sva #(
    .DATA_W        (AXIS_DATA_W),
    .USER_W        (AXIS_USER_W),
    .IF_NAME       ("s_axis_tx"),
    .DUT_IS_SOURCE (1'b1)
  ) u_sva_tx (
    .clk    (clk),
    .rst_n  (resetn),
    .tdata  (tx_if.tdata),
    .tkeep  (tx_if.tkeep),
    .tuser  (tx_if.tuser),
    .tlast  (tx_if.tlast),
    .tvalid (tx_if.tvalid),
    .tready (tx_if.tready)
  );

  openpcie_axis_sva #(
    .DATA_W        (AXIS_DATA_W),
    .USER_W        (AXIS_USER_W),
    .IF_NAME       ("m_axis_rx"),
    .DUT_IS_SOURCE (1'b0)
  ) u_sva_rx (
    .clk    (clk),
    .rst_n  (resetn),
    .tdata  (rx_if.tdata),
    .tkeep  (rx_if.tkeep),
    .tuser  (rx_if.tuser),
    .tlast  (rx_if.tlast),
    .tvalid (rx_if.tvalid),
    .tready (rx_if.tready)
  );

  //-----------------------------------------------------------------------
  // Firmware image sanity
  //-----------------------------------------------------------------------
  // riscv_pcie_soc.sv:99-101 reads firmware.hex unconditionally from the
  // current working directory.  If it is absent the CPU executes zeros and
  // every test dies later with an opaque mailbox timeout, so check up front.
  initial begin
    int fd;
    fd = $fopen("firmware.hex", "r");
    if (fd == 0)
      `uvm_fatal("TB", {"firmware.hex not found in the run directory. Build it ",
                        "with 'python tb/fw/build_fw.py' - the Makefile does this ",
                        "automatically via the 'fw' target."})
    $fclose(fd);
  end

  //-----------------------------------------------------------------------
  // Config DB and run
  //-----------------------------------------------------------------------
  initial begin
    uvm_config_db#(axis_vif_t)::set(null, "*", "rx_vif",  rx_if);
    uvm_config_db#(axis_vif_t)::set(null, "*", "tx_vif",  tx_if);
    uvm_config_db#(cfg_vif_t )::set(null, "*", "cfg_vif", cfg_if);

    // Reached by hierarchical name through the binds in tb/top/openpcie_bind.sv.
    uvm_config_db#(cpu_vif_t )::set(null, "*", "cpu_vif", dut.u_cpu_if);
    uvm_config_db#(ram_bkdr_vif_t)::set(null, "*", "bkdr_vif", dut.u_bkdr);

    uvm_config_db#(virtual openpcie_rst_if)::set(null, "*", "rst_vif", rst_if);

    run_test();
  end

  //-----------------------------------------------------------------------
  // Waves
  //-----------------------------------------------------------------------
  initial begin
    if ($test$plusargs("WAVES")) begin
`ifdef VCS
      $vcdplusfile("waves.vpd");
      $vcdpluson(0, tb_top);
`elsif XCELIUM
      $shm_open("waves.shm");
      $shm_probe(tb_top, "AS");
`else
      $dumpfile("waves.vcd");
      $dumpvars(0, tb_top);
`endif
    end
  end

endmodule
