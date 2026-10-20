//---------------------------------------------------------------------------
// openpcie_env - Tier 1 environment (DUT = riscv_pcie_soc)
//---------------------------------------------------------------------------
//
//    firmware mailbox (backdoor)                      openpcie_rst_if
//            |                                              |
//            v                                              v
//   +--------------------------- DUT: riscv_pcie_soc --------------------+
//   |  PicoRV32  --(mem bus, observed via bound cpu_if)--  PCIe bridge   |
//   +--------------------------------------------------------------------+
//        ^  m_axis_rx_*                              s_axis_tx_*  |
//        |                                                        v
//   rx agent (MASTER)                                     tx agent (SLAVE)
//        |  beat_ap                        ap |                   | ap
//        v                                    v                   v
//   +----------- predictor -----------+   scoreboard <--------- observed TX
//   |  shadow TX header regs          |       ^
//   |  shadow RX capture FSM          |-------+ expected TX
//   |  shadow sidebands               |
//   +---------------------------------+
//
// The predictor is fed from the CPU bus, not from sequence intent, so a
// firmware defect surfaces as a mismatch rather than moving stimulus and
// expectation together.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_ENV_SVH
`define OPENPCIE_ENV_SVH

class openpcie_env extends uvm_env;

  `uvm_component_utils(openpcie_env)

  openpcie_env_cfg                     cfg;

  openpcie_axis_pkg::openpcie_axis_agent rx_agent;
  openpcie_axis_pkg::openpcie_axis_agent tx_agent;
  openpcie_cfg_pkg::openpcie_cfg_agent   cfg_agent;
  openpcie_cpu_pkg::openpcie_cpu_agent   cpu_agent;

  openpcie_predictor     predictor;
  openpcie_scoreboard    scoreboard;
  openpcie_soc_coverage  coverage;
  openpcie_vseqr         vseqr;

  openpcie_fw_mailbox    mbox;
  openpcie_reg_block     ral;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  //-----------------------------------------------------------------------
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(openpcie_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("ENV", {"no openpcie_env_cfg in config DB - the test must ",
                         "create and publish one in its build_phase"})

    resolve_vifs();
    cfg.propagate_vifs();

    // -- agents ---------------------------------------------------------
    uvm_config_db#(openpcie_axis_pkg::openpcie_axis_cfg)
      ::set(this, "rx_agent", "cfg", cfg.rx_cfg);
    uvm_config_db#(openpcie_axis_pkg::openpcie_axis_cfg)
      ::set(this, "tx_agent", "cfg", cfg.tx_cfg);
    uvm_config_db#(openpcie_cfg_pkg::openpcie_cfg_agent_cfg)
      ::set(this, "cfg_agent", "cfg", cfg.cfg_cfg);
    uvm_config_db#(openpcie_cpu_pkg::openpcie_cpu_agent_cfg)
      ::set(this, "cpu_agent", "cfg", cfg.cpu_cfg);

    rx_agent  = openpcie_axis_pkg::openpcie_axis_agent::type_id::create("rx_agent",  this);
    tx_agent  = openpcie_axis_pkg::openpcie_axis_agent::type_id::create("tx_agent",  this);
    cfg_agent = openpcie_cfg_pkg::openpcie_cfg_agent  ::type_id::create("cfg_agent", this);
    cpu_agent = openpcie_cpu_pkg::openpcie_cpu_agent  ::type_id::create("cpu_agent", this);

    // -- analysis components --------------------------------------------
    if (cfg.enable_predictor)
      predictor = openpcie_predictor::type_id::create("predictor", this);

    if (cfg.enable_scoreboard)
      scoreboard = openpcie_scoreboard::type_id::create("scoreboard", this);

    if (cfg.enable_coverage)
      coverage = openpcie_soc_coverage::type_id::create("coverage", this);

    // -- stimulus plumbing ----------------------------------------------
    vseqr = openpcie_vseqr::type_id::create("vseqr", this);

    mbox                = openpcie_fw_mailbox::type_id::create("mbox");
    mbox.bkdr           = cfg.bkdr_vif;
    mbox.vif            = cfg.cpu_vif;

    if (cfg.build_ral) begin
      ral = openpcie_reg_block::type_id::create("ral");
      ral.build();
      install_frontdoors();
    end
  endfunction

  //-----------------------------------------------------------------------
  protected virtual function void resolve_vifs();
    if (cfg.rx_vif == null &&
        !uvm_config_db#(axis_vif_t)::get(this, "", "rx_vif", cfg.rx_vif))
      `uvm_fatal("ENV", "no rx_vif - tb_top must publish it")
    if (cfg.tx_vif == null &&
        !uvm_config_db#(axis_vif_t)::get(this, "", "tx_vif", cfg.tx_vif))
      `uvm_fatal("ENV", "no tx_vif - tb_top must publish it")
    if (cfg.cfg_vif == null &&
        !uvm_config_db#(cfg_vif_t)::get(this, "", "cfg_vif", cfg.cfg_vif))
      `uvm_fatal("ENV", "no cfg_vif - tb_top must publish it")
    if (cfg.cpu_vif == null &&
        !uvm_config_db#(cpu_vif_t)::get(this, "", "cpu_vif", cfg.cpu_vif))
      `uvm_fatal("ENV", {"no cpu_vif - check the bind of openpcie_cpu_if into ",
                         "riscv_pcie_soc in tb/top/openpcie_bind.sv"})
    if (cfg.bkdr_vif == null &&
        !uvm_config_db#(ram_bkdr_vif_t)::get(this, "", "bkdr_vif", cfg.bkdr_vif))
      `uvm_fatal("ENV", {"no bkdr_vif - check the bind of openpcie_ram_bkdr_if ",
                         "in tb/top/openpcie_bind.sv"})
    if (cfg.rst_vif == null &&
        !uvm_config_db#(virtual openpcie_rst_if)::get(this, "", "rst_vif",
                                                      cfg.rst_vif))
      `uvm_fatal("ENV", "no rst_vif - tb_top must publish it")
  endfunction

  // Every bridge register is reachable only through the CPU, so all nine get
  // the firmware frontdoor.  Without this, a RAL access would fall through to
  // the (nonexistent) bus adapter and hang.
  protected virtual function void install_frontdoors();
    uvm_reg          regs[$];
    ral.get_registers(regs);
    foreach (regs[i]) begin
      openpcie_fw_frontdoor fd =
        openpcie_fw_frontdoor::type_id::create($sformatf("fd_%s",
                                                         regs[i].get_name()));
      fd.mbox   = mbox;
      fd.offset = regs[i].get_offset(ral.map);
      regs[i].set_frontdoor(fd, ral.map);
    end
    `uvm_info("ENV", $sformatf("installed firmware frontdoor on %0d register(s)",
              regs.size()), UVM_MEDIUM)
  endfunction

  //-----------------------------------------------------------------------
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // stimulus handles
    vseqr.cfg      = cfg;
    vseqr.mbox     = mbox;
    vseqr.ral      = ral;
    vseqr.rst_vif  = cfg.rst_vif;
    if (rx_agent.sequencer  != null) vseqr.rx_seqr  = rx_agent.sequencer;
    if (cfg_agent.sequencer != null) vseqr.cfg_seqr = cfg_agent.sequencer;

    // predictor inputs
    if (predictor != null) begin
      predictor.settle_ns = cfg.clk_period_ns * 6;
      cpu_agent.ap.connect(predictor.cpu_imp);
      cfg_agent.ap.connect(predictor.cfg_imp);
      rx_agent.beat_ap.connect(predictor.rx_imp);
    end

    // scoreboard inputs
    if (scoreboard != null) begin
      scoreboard.predictor          = predictor;
      scoreboard.require_tx_activity = cfg.require_tx_activity;
      tx_agent.ap.connect(scoreboard.act_tx_imp);
      cpu_agent.ap.connect(scoreboard.rdbk_imp);
      if (predictor != null)
        predictor.exp_tx_ap.connect(scoreboard.exp_tx_imp);
      else
        `uvm_warning("ENV", {"scoreboard enabled without a predictor - TX ",
                             "checking will be inert"})
    end

    // coverage inputs
    if (coverage != null) begin
      cpu_agent.ap.connect(coverage.cpu_imp);
      tx_agent.ap.connect(coverage.tx_imp);
      cfg_agent.ap.connect(coverage.cfg_imp);
    end
  endfunction

endclass

`endif // OPENPCIE_ENV_SVH
