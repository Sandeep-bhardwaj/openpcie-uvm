//---------------------------------------------------------------------------
// openpcie_env_cfg - single point of control for the Tier 1 environment
//---------------------------------------------------------------------------
// Tests mutate this object in build_phase before the env is built.  Nothing
// else in the environment reads the config DB for policy, so there is exactly
// one place to look when asking "why did this test behave that way".
//---------------------------------------------------------------------------

`ifndef OPENPCIE_ENV_CFG_SVH
`define OPENPCIE_ENV_CFG_SVH

class openpcie_env_cfg extends uvm_object;

  // Registration is done once, by the `uvm_object_utils_begin/end block
  // further down that also declares the field automation.

  // ---- virtual interfaces ---------------------------------------------
  axis_vif_t                       rx_vif;   // TB -> DUT (m_axis_rx_*)
  axis_vif_t                       tx_vif;   // DUT -> TB (s_axis_tx_*)
  cfg_vif_t                        cfg_vif;
  cpu_vif_t                        cpu_vif;
  ram_bkdr_vif_t                   bkdr_vif; // SoC RAM backdoor (mailbox)
  virtual openpcie_rst_if          rst_vif;

  // ---- sub-configs (built by the env, tweakable by tests) --------------
  openpcie_axis_pkg::openpcie_axis_cfg      rx_cfg;
  openpcie_axis_pkg::openpcie_axis_cfg      tx_cfg;
  openpcie_cfg_pkg::openpcie_cfg_agent_cfg  cfg_cfg;
  openpcie_cpu_pkg::openpcie_cpu_agent_cfg  cpu_cfg;

  // ---- environment policy ---------------------------------------------
  bit    enable_scoreboard   = 1;
  bit    enable_coverage     = 1;
  bit    enable_predictor    = 1;
  bit    require_tx_activity = 1;

  bit    build_ral           = 1;

  // Clock period in ns; the predictor uses it to decide when a sideband has
  // settled enough for a status readback to be strictly checkable.
  int unsigned clk_period_ns = 16;   // 62.5 MHz user_clk for x1 Gen2

  `uvm_object_utils_begin(openpcie_env_cfg)
    `uvm_field_int   (enable_scoreboard,   UVM_ALL_ON)
    `uvm_field_int   (enable_coverage,     UVM_ALL_ON)
    `uvm_field_int   (enable_predictor,    UVM_ALL_ON)
    `uvm_field_int   (require_tx_activity, UVM_ALL_ON)
    `uvm_field_int   (build_ral,           UVM_ALL_ON)
    `uvm_field_int   (clk_period_ns,       UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "openpcie_env_cfg");
    super.new(name);
    rx_cfg  = openpcie_axis_pkg::openpcie_axis_cfg    ::type_id::create("rx_cfg");
    tx_cfg  = openpcie_axis_pkg::openpcie_axis_cfg    ::type_id::create("tx_cfg");
    cfg_cfg = openpcie_cfg_pkg::openpcie_cfg_agent_cfg::type_id::create("cfg_cfg");
    cpu_cfg = openpcie_cpu_pkg::openpcie_cpu_agent_cfg::type_id::create("cpu_cfg");

    // The DUT sources s_axis_tx_* and sinks m_axis_rx_*, so the TB takes the
    // opposite role on each.
    rx_cfg.role     = AXIS_ROLE_MASTER;
    rx_cfg.name_tag = "rx";

    tx_cfg.role       = AXIS_ROLE_SLAVE;
    tx_cfg.name_tag   = "tx";
    tx_cfg.ready_mode = READY_ALWAYS;   // tests override to stress the FSM

    // This environment is Tier 1: riscv_pcie_soc only ever moves two-beat
    // packets, so packet-shape coverage is scored against that.
    rx_cfg.tier1_shapes = 1;
    tx_cfg.tier1_shapes = 1;
  endfunction

  // Called by the env once the virtual interfaces have been resolved.
  function void propagate_vifs();
    rx_cfg.vif  = rx_vif;
    tx_cfg.vif  = tx_vif;
    cfg_cfg.vif = cfg_vif;
    cpu_cfg.vif = cpu_vif;
    rx_cfg.enable_coverage = enable_coverage;
    tx_cfg.enable_coverage = enable_coverage;
  endfunction

endclass

`endif // OPENPCIE_ENV_CFG_SVH
