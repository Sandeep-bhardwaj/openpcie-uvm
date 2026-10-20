//---------------------------------------------------------------------------
// openpcie_fw_mailbox - UVM-side half of the firmware command mailbox
//---------------------------------------------------------------------------
// `riscv_pcie_soc` embeds a PicoRV32 and reaches the PCIe bridge only through
// it, so the environment cannot drive bridge registers directly.  The mailbox
// firmware (tb/fw/mailbox_fw.s) spins on a small structure in the SoC's RAM; this
// class posts commands into that structure by backdoor and waits for the
// firmware's completion counter to advance.
//
// The backdoor is openpcie_ram_bkdr_if, bound into the DUT onto its `ram`.
// Its writes are plain assignments, not forces: the RTL stays free to write
// the same location afterwards, which is exactly what the firmware does when
// it clears CMD.  A force would deadlock the handshake.
//
// Handshake (mirrors the contract documented in tb/fw/mailbox_fw.s):
//   TB  : write ARG0..ARG3, then write CMD
//   FW  : execute, write RSP, clear CMD, then increment ACK
//   TB  : wait for ACK to change, then read RSP
// Because the firmware clears CMD *before* bumping ACK, an observer that waits
// on ACK is guaranteed to find the mailbox released.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_FW_MAILBOX_SVH
`define OPENPCIE_FW_MAILBOX_SVH

class openpcie_fw_mailbox extends uvm_object;

  `uvm_object_utils(openpcie_fw_mailbox)

  // Backdoor onto the SoC RAM array (tb_top.dut.u_bkdr).
  ram_bkdr_vif_t bkdr;

  // Clock the wait loops sample on.
  cpu_vif_t  vif;

  // Guards the whole post/wait sequence so concurrent sequences on the
  // virtual sequencer cannot interleave two commands into one mailbox.
  protected semaphore m_lock;

  int unsigned timeout_cycles = 20000;
  int unsigned commands_issued;
  bit          fw_alive;

  function new(string name = "openpcie_fw_mailbox");
    super.new(name);
    m_lock = new(1);
  endfunction

  // -- raw backdoor primitives -----------------------------------------
  virtual function bit poke(bit [31:0] byte_addr, bit [31:0] value);
    if (bkdr == null) begin
      `uvm_error("FWBOX", "no RAM backdoor - check the bind of openpcie_ram_bkdr_if")
      return 0;
    end
    bkdr.wr_word(byte_addr >> 2, value);
    return 1;
  endfunction

  virtual function bit peek(bit [31:0] byte_addr, output bit [31:0] value);
    if (bkdr == null) begin
      `uvm_error("FWBOX", "no RAM backdoor - check the bind of openpcie_ram_bkdr_if")
      value = 'x;
      return 0;
    end
    value = bkdr.rd_word(byte_addr >> 2);
    return 1;
  endfunction

  // Human-readable snapshot of the whole mailbox, for failure messages.
  virtual function string dump();
    bit [31:0] c, a0, a1, a2, a3, r, k, al;
    void'(peek(MBOX_CMD,  c));  void'(peek(MBOX_ARG0, a0));
    void'(peek(MBOX_ARG1, a1)); void'(peek(MBOX_ARG2, a2));
    void'(peek(MBOX_ARG3, a3)); void'(peek(MBOX_RSP,  r));
    void'(peek(MBOX_ACK,  k));  void'(peek(MBOX_ALIVE, al));
    return $sformatf(
      {"  mailbox @ 0x%04h\n",
       "    CMD =%08h  ARG0=%08h  ARG1=%08h  ARG2=%08h\n",
       "    ACK =%08h  ARG3=%08h  RSP =%08h  ALIVE=%08h\n"},
      MBOX_BASE, c, a0, a1, a2, k, a3, r, al);
  endfunction

  // -- lifecycle --------------------------------------------------------

  // Blocks until the firmware has written its boot magic.  Proves reset
  // release, instruction fetch from RAM and the store path all work before
  // any test-specific stimulus is attempted.
  virtual task wait_for_boot(int unsigned max_cycles = 5000);
    bit [31:0] v;
    int unsigned n = 0;
    `uvm_info("FWBOX", "waiting for firmware boot magic", UVM_MEDIUM)
    forever begin
      @(vif.mon_cb);
      void'(peek(MBOX_ALIVE, v));
      if (v === MBOX_ALIVE_MAGIC) begin
        fw_alive = 1;
        `uvm_info("FWBOX", $sformatf(
          "firmware alive after %0d cycles (ALIVE=0x%08h)", n, v), UVM_LOW)
        return;
      end
      if (++n > max_cycles) begin
        `uvm_fatal("FWBOX", $sformatf(
          {"firmware did not boot within %0d cycles (ALIVE=0x%08h, expected ",
           "0x%08h). Check that firmware.hex is present in the run directory."},
          max_cycles, v, MBOX_ALIVE_MAGIC))
      end
    end
  endtask

  // -- command primitive ------------------------------------------------
  virtual task automatic issue(input fw_cmd_e cmd,
                               input bit [31:0] a0 = 0,
                               input bit [31:0] a1 = 0,
                               input bit [31:0] a2 = 0,
                               input bit [31:0] a3 = 0,
                               output bit [31:0] rsp);
    bit [31:0] ack0, ack, cmd_rb;
    int unsigned n = 0;

    m_lock.get(1);

    if (!peek(MBOX_ACK, ack0)) begin
      m_lock.put(1);
      return;
    end

    void'(poke(MBOX_ARG0, a0));
    void'(poke(MBOX_ARG1, a1));
    void'(poke(MBOX_ARG2, a2));
    void'(poke(MBOX_ARG3, a3));
    void'(poke(MBOX_CMD,  cmd));

    `uvm_info("FWBOX", $sformatf("posted %s a0=%08h a1=%08h a2=%08h a3=%08h",
              cmd.name(), a0, a1, a2, a3), UVM_HIGH)

    forever begin
      @(vif.mon_cb);
      void'(peek(MBOX_ACK, ack));
      if (ack !== ack0) break;
      if (++n > timeout_cycles) begin
        m_lock.put(1);
        `uvm_fatal("FWBOX", $sformatf(
          {"%s did not complete within %0d cycles (ACK never left %0d).\n%s",
           "How to read this:\n",
           "  CMD still holds the command -> the CPU is stalled, or never ",
           "reached its poll loop.\n",
           "  CMD is 0 and ACK is 0      -> the command was posted but wiped ",
           "before the poll loop saw it (a boot-ordering race).\n",
           "  ALIVE is not 0x%08h        -> the loaded firmware is not the ",
           "one this class expects."},
          cmd.name(), timeout_cycles, ack0, dump(), MBOX_ALIVE_MAGIC))
      end
    end

    // The firmware clears CMD before bumping ACK, so this must hold.
    void'(peek(MBOX_CMD, cmd_rb));
    if (cmd_rb !== 32'h0)
      `uvm_error("FWBOX", $sformatf(
        {"mailbox handshake violated: ACK advanced to %0d but CMD is still ",
         "0x%08h"}, ack, cmd_rb))

    void'(peek(MBOX_RSP, rsp));
    commands_issued++;
    m_lock.put(1);
  endtask

  // -- typed helpers ----------------------------------------------------

  // Post a complete TLP: three header DWs plus one payload DW.  The firmware
  // writes TX_DATA last, which is what arms the transmit FSM.
  virtual task automatic send_tlp(bit [31:0] dw0, bit [31:0] dw1,
                                  bit [31:0] dw2, bit [31:0] payload);
    bit [31:0] rsp;
    issue(FW_CMD_SEND_TLP, dw0, dw1, dw2, payload, rsp);
  endtask

  virtual task automatic read_reg(input bit [31:0] offset,
                                  output bit [31:0] value);
    issue(FW_CMD_READ_REG, offset, 0, 0, 0, value);
  endtask

  virtual task automatic write_reg(bit [31:0] offset, bit [31:0] value);
    bit [31:0] rsp;
    issue(FW_CMD_WRITE_REG, offset, value, 0, 0, rsp);
  endtask

  // Ordering barrier: completes only after every previously posted command
  // has been retired by the firmware.
  virtual task automatic sync();
    bit [31:0] rsp;
    issue(FW_CMD_NOP, 0, 0, 0, 0, rsp);
  endtask

endclass

`endif // OPENPCIE_FW_MAILBOX_SVH
