//---------------------------------------------------------------------------
// openpcie_cpu_pkg - passive PicoRV32 memory-bus agent
//---------------------------------------------------------------------------
// Watches every CPU access inside `riscv_pcie_soc` through a bound interface.
// This is the environment's stimulus-independent view of what the firmware
// actually did, and it is what the predictor uses to build expected TLPs.
//
// Passive by construction: there is no driver.  Stimulus reaches the CPU only
// through the backdoor mailbox (openpcie_fw_mailbox), never by forcing this
// bus.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_CPU_PKG_SV
`define OPENPCIE_CPU_PKG_SV

package openpcie_cpu_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import openpcie_types_pkg::*;

  typedef enum { CPU_READ, CPU_WRITE } cpu_dir_e;

  //-----------------------------------------------------------------------
  // Item - one completed CPU bus transfer
  //-----------------------------------------------------------------------
  class openpcie_cpu_item extends uvm_sequence_item;

    cpu_dir_e    dir;
    bit [31:0]   addr;
    bit [31:0]   wdata;
    bit [31:0]   rdata;
    bit [3:0]    wstrb;
    bit          to_bridge;      // addr[31:24] == 0x30
    bit          to_ram;         // addr[31:24] == 0x00
    bit [31:0]   bridge_offset;  // addr & 0x3F  (decode is 64-byte periodic)
    time         t;

    `uvm_object_utils_begin(openpcie_cpu_item)
      `uvm_field_enum(cpu_dir_e, dir,       UVM_ALL_ON)
      `uvm_field_int (addr,                 UVM_ALL_ON)
      `uvm_field_int (wdata,                UVM_ALL_ON)
      `uvm_field_int (rdata,                UVM_ALL_ON)
      `uvm_field_int (wstrb,                UVM_ALL_ON)
      `uvm_field_int (to_bridge,            UVM_ALL_ON)
      `uvm_field_int (bridge_offset,        UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "openpcie_cpu_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("CPU %s addr=%08h %s%s",
                       (dir == CPU_WRITE) ? "WR" : "RD", addr,
                       (dir == CPU_WRITE) ? $sformatf("wdata=%08h strb=%1h",
                                                      wdata, wstrb)
                                          : $sformatf("rdata=%08h", rdata),
                       to_bridge ? $sformatf("  [bridge +0x%02h]", bridge_offset)
                                 : "");
    endfunction
  endclass

  //-----------------------------------------------------------------------
  // Config
  //-----------------------------------------------------------------------
  class openpcie_cpu_agent_cfg extends uvm_object;
    cpu_vif_t vif;
    bit       bridge_only = 1;   // suppress the (very noisy) RAM/fetch traffic
    `uvm_object_utils(openpcie_cpu_agent_cfg)
    function new(string name = "openpcie_cpu_agent_cfg");
      super.new(name);
    endfunction
  endclass

  //-----------------------------------------------------------------------
  // Monitor
  //-----------------------------------------------------------------------
  class openpcie_cpu_monitor extends uvm_monitor;
    `uvm_component_utils(openpcie_cpu_monitor)

    openpcie_cpu_agent_cfg cfg;
    cpu_vif_t              vif;

    uvm_analysis_port #(openpcie_cpu_item) ap;

    int unsigned bridge_writes;
    int unsigned bridge_reads;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(openpcie_cpu_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CPU/MON", "no openpcie_cpu_agent_cfg in config DB")
      vif = cfg.vif;
    endfunction

    // PicoRV32 native bus: mem_valid is held until mem_ready pulses for one
    // cycle.  Sampling on the ready pulse gives exactly one item per transfer
    // regardless of how many wait states the slave inserted.
    task run_phase(uvm_phase phase);
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.mem_valid === 1'b1 && vif.mon_cb.mem_ready === 1'b1) begin
          openpcie_cpu_item it;
          bit is_bridge = (vif.mon_cb.mem_addr[31:24] == 8'h30);

          if (cfg.bridge_only && !is_bridge) continue;

          it               = openpcie_cpu_item::type_id::create("cpu_item");
          it.addr          = vif.mon_cb.mem_addr;
          it.wstrb         = vif.mon_cb.mem_wstrb;
          it.dir           = (vif.mon_cb.mem_wstrb != 4'h0) ? CPU_WRITE : CPU_READ;
          it.wdata         = vif.mon_cb.mem_wdata;
          it.rdata         = vif.mon_cb.mem_rdata;
          it.to_bridge     = is_bridge;
          it.to_ram        = (vif.mon_cb.mem_addr[31:24] == 8'h00);
          it.bridge_offset = vif.mon_cb.mem_addr & 32'h0000_003F;
          it.t             = $time;

          if (is_bridge) begin
            if (it.dir == CPU_WRITE) bridge_writes++; else bridge_reads++;
          end

          `uvm_info("CPU/MON", it.convert2string(), UVM_HIGH)
          ap.write(it);
        end
      end
    endtask

    function void report_phase(uvm_phase phase);
      `uvm_info("CPU/MON", $sformatf(
        "bridge traffic: %0d write(s), %0d read(s)",
        bridge_writes, bridge_reads), UVM_LOW)
      if (bridge_writes == 0 && bridge_reads == 0)
        `uvm_error("CPU/MON",
          {"no CPU access to the bridge was ever observed - the firmware is ",
           "not running, or the mailbox handshake never completed"})
    endfunction
  endclass

  //-----------------------------------------------------------------------
  // Agent (passive only)
  //-----------------------------------------------------------------------
  class openpcie_cpu_agent extends uvm_agent;
    `uvm_component_utils(openpcie_cpu_agent)

    openpcie_cpu_agent_cfg cfg;
    openpcie_cpu_monitor   monitor;
    uvm_analysis_port #(openpcie_cpu_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(openpcie_cpu_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CPU/AGT", "no openpcie_cpu_agent_cfg in config DB")
      uvm_config_db#(openpcie_cpu_agent_cfg)::set(this, "*", "cfg", cfg);
      is_active = UVM_PASSIVE;
      monitor   = openpcie_cpu_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      ap = monitor.ap;
    endfunction
  endclass

endpackage

`endif // OPENPCIE_CPU_PKG_SV
