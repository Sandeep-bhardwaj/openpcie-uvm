//---------------------------------------------------------------------------
// openpcie_test_lib - Tier 1 test library
//---------------------------------------------------------------------------
// Tests own *policy* (which backpressure profile, whether the scoreboard is
// armed, how long the timeout is).  Sequences own *stimulus*.  Keeping the
// split clean is what lets the same sequence run under several profiles.
//
// Run one with:  make TEST=openpcie_smoke_test SEED=1
//---------------------------------------------------------------------------

`ifndef OPENPCIE_TEST_LIB_SVH
`define OPENPCIE_TEST_LIB_SVH

//---------------------------------------------------------------------------
// Base test - builds the env, sets the global timeout, prints the summary.
//---------------------------------------------------------------------------
class openpcie_base_test extends uvm_test;

  `uvm_component_utils(openpcie_base_test)

  openpcie_env      env;
  openpcie_env_cfg  cfg;

  // Generous by default: the firmware mailbox is a polling handshake, so a
  // long random test legitimately takes a while.  Tests shorten or extend it.
  time test_timeout = 20ms;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    cfg = openpcie_env_cfg::type_id::create("cfg");
    configure();
    uvm_config_db#(openpcie_env_cfg)::set(this, "env", "cfg", cfg);

    env = openpcie_env::type_id::create("env", this);
  endfunction

  // Overridden by derived tests to change policy before the env is built.
  virtual function void configure();
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    uvm_top.set_timeout(test_timeout, 1);
    if (uvm_report_enabled(UVM_HIGH))
      uvm_top.print_topology();
  endfunction

  // Run the sequence named by the derived test.  Centralising this keeps
  // every test's run_phase identical and objection-safe.
  protected string m_vseq_name = "";

  virtual task run_phase(uvm_phase phase);
    uvm_object        o;
    uvm_sequence_base seq;
    uvm_factory       f;

    if (m_vseq_name == "") begin
      `uvm_info(get_type_name(), "no sequence configured - idling", UVM_LOW)
      return;
    end

    phase.raise_objection(this, m_vseq_name);

    // uvm_factory::get() rather than the global `factory` handle: the global
    // was removed between UVM 1.2 and 1800.2-2020, this accessor exists in both.
    f = uvm_factory::get();
    o = f.create_object_by_name(m_vseq_name, get_full_name(), m_vseq_name);
    if (o == null || !$cast(seq, o))
      `uvm_fatal(get_type_name(), $sformatf(
        {"'%s' is not a registered uvm_sequence - check the `uvm_object_utils ",
         "registration in tb/seq"}, m_vseq_name))

    if (!seq.randomize())
      `uvm_warning(get_type_name(), $sformatf("randomize of %s failed",
                                              m_vseq_name))

    seq.start(env.vseqr);

    phase.drop_objection(this, m_vseq_name);
  endtask

  virtual function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    int unsigned n_err  = svr.get_severity_count(UVM_ERROR);
    int unsigned n_fatal= svr.get_severity_count(UVM_FATAL);
    int unsigned n_warn = svr.get_severity_count(UVM_WARNING);

    $display("");
    $display("================================================================");
    if (n_err == 0 && n_fatal == 0)
      $display("  TEST PASSED : %s   (%0d warning(s))", get_type_name(), n_warn);
    else
      $display("  TEST FAILED : %s   (%0d error(s), %0d fatal, %0d warning(s))",
               get_type_name(), n_err, n_fatal, n_warn);
    $display("================================================================");
    $display("");
  endfunction

endclass


//---------------------------------------------------------------------------
// Smoke - permissive sink, minimal traffic.  The gate for every other test.
//---------------------------------------------------------------------------
class openpcie_smoke_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_smoke_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_smoke_vseq";
    test_timeout = 2ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode = READY_ALWAYS;
  endfunction
endclass


//---------------------------------------------------------------------------
// Directed TX shapes.
//---------------------------------------------------------------------------
class openpcie_tx_directed_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_tx_directed_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_tx_directed_vseq";
    test_timeout = 10ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode = READY_ALWAYS;
  endfunction
endclass


//---------------------------------------------------------------------------
// Random TX traffic, permissive sink.
//---------------------------------------------------------------------------
class openpcie_tx_random_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_tx_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name = "openpcie_tx_random_vseq";
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode = READY_ALWAYS;
  endfunction
endclass


//---------------------------------------------------------------------------
// TX under randomised backpressure.
//
// This is the test aimed squarely at the transmit FSM's early tready
// sampling (riscv_pcie_soc.sv:195-211).  If the RTL is as written, expect
// AXIS/PROTO stability errors and TX packet mismatches here while
// openpcie_tx_random_test passes - that difference is the diagnosis.
//---------------------------------------------------------------------------
class openpcie_tx_backpressure_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_tx_backpressure_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_tx_backpressure_vseq";
    test_timeout = 20ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode = READY_RANDOM;
    cfg.tx_cfg.ready_pct  = 40;      // stall more often than not
  endfunction
endclass


// Same stimulus, deterministic stall pattern - easier to debug than random.
class openpcie_tx_slow_sink_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_tx_slow_sink_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_tx_backpressure_vseq";
    test_timeout = 20ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode   = READY_SLOW;
    cfg.tx_cfg.ready_period = 4;     // one beat accepted every 4 cycles
  endfunction
endclass


// Bursty sink - alternating accept and stall runs.
class openpcie_tx_burst_sink_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_tx_burst_sink_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_tx_backpressure_vseq";
    test_timeout = 20ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode   = READY_BURST;
    cfg.tx_cfg.burst_accept = 1;
    cfg.tx_cfg.burst_stall  = 3;
  endfunction
endclass


//---------------------------------------------------------------------------
// RX completion capture.  No TX traffic is generated, so the scoreboard's
// end-of-test activity requirement is relaxed.
//---------------------------------------------------------------------------
class openpcie_rx_cpl_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_rx_cpl_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_rx_cpl_vseq";
    test_timeout = 20ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode    = READY_ALWAYS;
    cfg.require_tx_activity  = 0;
  endfunction
endclass


//---------------------------------------------------------------------------
// RAL-driven register access.
//---------------------------------------------------------------------------
class openpcie_reg_access_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_reg_access_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_reg_access_vseq";
    test_timeout = 10ms;
  endfunction

  virtual function void configure();
    cfg.build_ral         = 1;
    cfg.tx_cfg.ready_mode = READY_ALWAYS;
  endfunction
endclass


//---------------------------------------------------------------------------
// Sideband movement during traffic.
//---------------------------------------------------------------------------
class openpcie_sideband_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_sideband_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_sideband_vseq";
    test_timeout = 20ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode = READY_ALWAYS;
  endfunction
endclass


//---------------------------------------------------------------------------
// Reset recovery.
//---------------------------------------------------------------------------
class openpcie_reset_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_reset_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_reset_vseq";
    test_timeout = 20ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode = READY_ALWAYS;
  endfunction
endclass


//---------------------------------------------------------------------------
// Mixed random traffic under random backpressure - the nightly workhorse.
//---------------------------------------------------------------------------
class openpcie_random_test extends openpcie_base_test;
  `uvm_component_utils(openpcie_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    m_vseq_name  = "openpcie_random_vseq";
    test_timeout = 60ms;
  endfunction

  virtual function void configure();
    cfg.tx_cfg.ready_mode = READY_RANDOM;
    cfg.tx_cfg.ready_pct  = 65;
  endfunction
endclass

`endif // OPENPCIE_TEST_LIB_SVH
