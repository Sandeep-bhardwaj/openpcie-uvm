//---------------------------------------------------------------------------
// openpcie_ral - register abstraction for the PCIe bridge in riscv_pcie_soc
//---------------------------------------------------------------------------
// Modelled from riscv_pcie_soc.sv:176-254.
//
// Two things about this block are unusual and are modelled deliberately:
//
//  1. The address decode uses only mem_addr[5] and mem_addr[4:2], so the whole
//     16 MiB window at 0x30xxxxxx aliases with a 64-byte period.  The block is
//     therefore declared 64 bytes wide; anything above that is a mirror.
//
//  2. The four TX registers are write-only.  Reads of 0x00..0x0C fall into the
//     `default` arm of the read case and return 0, so they are declared "WO"
//     and excluded from the built-in read/write sequences.  Declaring them RW
//     would make uvm_reg_bit_bash_seq fail against correct RTL.
//
// The frontdoor is the firmware mailbox: no bus agent can reach these
// registers, only the PicoRV32 can.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_RAL_SVH
`define OPENPCIE_RAL_SVH

//---------------------------------------------------------------------------
// Registers
//---------------------------------------------------------------------------

class openpcie_reg_tx_hdr extends uvm_reg;
  `uvm_object_utils(openpcie_reg_tx_hdr)
  rand uvm_reg_field value;

  function new(string name = "openpcie_reg_tx_hdr");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, 32, 0, "WO", 0, 32'h0, 1, 1, 1);
  endfunction
endclass


class openpcie_reg_tx_data extends uvm_reg;
  `uvm_object_utils(openpcie_reg_tx_data)
  rand uvm_reg_field value;

  function new(string name = "openpcie_reg_tx_data");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, 32, 0, "WO", 0, 32'h0, 1, 1, 1);
  endfunction
endclass


class openpcie_reg_rx_status extends uvm_reg;
  `uvm_object_utils(openpcie_reg_rx_status)
  uvm_reg_field cpl_status;   // [2:0]  captured from RX DW1[15:13]
  uvm_reg_field rsvd;

  function new(string name = "openpcie_reg_rx_status");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    cpl_status = uvm_reg_field::type_id::create("cpl_status");
    rsvd       = uvm_reg_field::type_id::create("rsvd");
    cpl_status.configure(this,  3, 0, "RO", 1, 3'h0,  1, 0, 0);
    rsvd      .configure(this, 29, 3, "RO", 1, 29'h0, 1, 0, 0);
  endfunction
endclass


class openpcie_reg_ro32 extends uvm_reg;
  `uvm_object_utils(openpcie_reg_ro32)
  uvm_reg_field value;

  function new(string name = "openpcie_reg_ro32");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, 32, 0, "RO", 1, 32'h0, 1, 0, 0);
  endfunction
endclass


class openpcie_reg_err_status extends uvm_reg;
  `uvm_object_utils(openpcie_reg_err_status)
  uvm_reg_field cfg_status;   // [15:0]
  uvm_reg_field err_fatal;    // [16]
  uvm_reg_field rsvd;

  function new(string name = "openpcie_reg_err_status");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    cfg_status = uvm_reg_field::type_id::create("cfg_status");
    err_fatal  = uvm_reg_field::type_id::create("err_fatal");
    rsvd       = uvm_reg_field::type_id::create("rsvd");
    cfg_status.configure(this, 16,  0, "RO", 1, 16'h0, 1, 0, 0);
    err_fatal .configure(this,  1, 16, "RO", 1,  1'h0, 1, 0, 0);
    rsvd      .configure(this, 15, 17, "RO", 1, 15'h0, 1, 0, 0);
  endfunction
endclass


class openpcie_reg_phy_status extends uvm_reg;
  `uvm_object_utils(openpcie_reg_phy_status)
  uvm_reg_field tx_buf_av;    // [5:0]
  uvm_reg_field tx_state;     // [7:6]
  uvm_reg_field rsvd;

  function new(string name = "openpcie_reg_phy_status");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    tx_buf_av = uvm_reg_field::type_id::create("tx_buf_av");
    tx_state  = uvm_reg_field::type_id::create("tx_state");
    rsvd      = uvm_reg_field::type_id::create("rsvd");
    tx_buf_av.configure(this,  6, 0, "RO", 1,  6'h0, 1, 0, 0);
    tx_state .configure(this,  2, 6, "RO", 1,  2'h0, 1, 0, 0);
    rsvd     .configure(this, 24, 8, "RO", 1, 24'h0, 1, 0, 0);
  endfunction
endclass


//---------------------------------------------------------------------------
// Block
//---------------------------------------------------------------------------
class openpcie_reg_block extends uvm_reg_block;
  `uvm_object_utils(openpcie_reg_block)

  rand openpcie_reg_tx_hdr     TX_HDR0;
  rand openpcie_reg_tx_hdr     TX_HDR1;
  rand openpcie_reg_tx_hdr     TX_HDR2;
  rand openpcie_reg_tx_data    TX_DATA;
       openpcie_reg_rx_status  RX_STATUS;
       openpcie_reg_ro32       RX_DATA;
       openpcie_reg_ro32       RX_HDR_INFO;
       openpcie_reg_err_status ERR_STATUS;
       openpcie_reg_phy_status PHY_STATUS;

  uvm_reg_map map;

  function new(string name = "openpcie_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN, 1);

    TX_HDR0     = openpcie_reg_tx_hdr    ::type_id::create("TX_HDR0");
    TX_HDR1     = openpcie_reg_tx_hdr    ::type_id::create("TX_HDR1");
    TX_HDR2     = openpcie_reg_tx_hdr    ::type_id::create("TX_HDR2");
    TX_DATA     = openpcie_reg_tx_data   ::type_id::create("TX_DATA");
    RX_STATUS   = openpcie_reg_rx_status ::type_id::create("RX_STATUS");
    RX_DATA     = openpcie_reg_ro32      ::type_id::create("RX_DATA");
    RX_HDR_INFO = openpcie_reg_ro32      ::type_id::create("RX_HDR_INFO");
    ERR_STATUS  = openpcie_reg_err_status::type_id::create("ERR_STATUS");
    PHY_STATUS  = openpcie_reg_phy_status::type_id::create("PHY_STATUS");

    foreach_build();

    map.add_reg(TX_HDR0,     32'h00, "WO");
    map.add_reg(TX_HDR1,     32'h04, "WO");
    map.add_reg(TX_HDR2,     32'h08, "WO");
    map.add_reg(TX_DATA,     32'h0C, "WO");
    map.add_reg(RX_STATUS,   32'h10, "RO");
    map.add_reg(RX_DATA,     32'h14, "RO");
    map.add_reg(RX_HDR_INFO,32'h18, "RO");
    map.add_reg(ERR_STATUS,  32'h1C, "RO");
    map.add_reg(PHY_STATUS,  32'h20, "RO");

    lock_model();
  endfunction

  local function void foreach_build();
    TX_HDR0    .configure(this, null, ""); TX_HDR0    .build();
    TX_HDR1    .configure(this, null, ""); TX_HDR1    .build();
    TX_HDR2    .configure(this, null, ""); TX_HDR2    .build();
    TX_DATA    .configure(this, null, ""); TX_DATA    .build();
    RX_STATUS  .configure(this, null, ""); RX_STATUS  .build();
    RX_DATA    .configure(this, null, ""); RX_DATA    .build();
    RX_HDR_INFO.configure(this, null, ""); RX_HDR_INFO.build();
    ERR_STATUS .configure(this, null, ""); ERR_STATUS .build();
    PHY_STATUS .configure(this, null, ""); PHY_STATUS .build();
  endfunction

endclass


//---------------------------------------------------------------------------
// Frontdoor - routes every RAL access through the firmware mailbox
//---------------------------------------------------------------------------
class openpcie_fw_frontdoor extends uvm_reg_frontdoor;

  `uvm_object_utils(openpcie_fw_frontdoor)

  openpcie_fw_mailbox mbox;
  bit [31:0]          offset;

  function new(string name = "openpcie_fw_frontdoor");
    super.new(name);
  endfunction

  virtual task body();
    bit [31:0] value;

    if (mbox == null) begin
      `uvm_error("RAL/FD", "frontdoor has no mailbox handle")
      rw_info.status = UVM_NOT_OK;
      return;
    end

    if (rw_info.kind inside {UVM_WRITE, UVM_BURST_WRITE}) begin
      mbox.write_reg(offset, rw_info.value[0]);
      rw_info.status = UVM_IS_OK;
    end
    else begin
      mbox.read_reg(offset, value);
      rw_info.value    = new[1];
      rw_info.value[0] = value;
      rw_info.status   = UVM_IS_OK;
    end
  endtask

endclass

`endif // OPENPCIE_RAL_SVH
