//---------------------------------------------------------------------------
// openPCIE UVM - Transaction Layer Packet model
//---------------------------------------------------------------------------
// Field layout per PCI Express Base Specification Rev 2.1 section 2.2.
// The spec is available from PCI-SIG; it is not redistributed here.
//
//   DW0  [31]    R          [30:29] Fmt      [28:24] Type   [23] R
//        [22:20] TC         [19:16] R        [15] TD        [14] EP
//        [13:12] Attr       [11:10] AT       [9:0]  Length
//
//   DW1 (memory request)     [31:16] Requester ID [15:8] Tag
//                            [7:4]  Last DW BE    [3:0]  First DW BE
//   DW1 (completion)         [31:16] Completer ID [15:13] Status
//                            [12] BCM             [11:0] Byte Count
//
//   DW2 (32-bit mem request) [31:2] Address[31:2] [1:0] R
//   DW2 (completion)         [31:16] Requester ID [15:8] Tag
//                            [7] R                [6:0]  Lower Address
//
// Fmt[1] (DW0 bit 30) is the "has payload" bit.  The DUT relies on exactly
// that bit to size the final beat's tkeep (riscv_pcie_soc.sv:204), so the
// model and the RTL agree by construction.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_TLP_PKG_SV
`define OPENPCIE_TLP_PKG_SV

package openpcie_tlp_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---- Fmt / Type ------------------------------------------------------
  typedef enum bit [1:0] {
    FMT_3DW_ND = 2'b00,   // 3 DW header, no data
    FMT_4DW_ND = 2'b01,   // 4 DW header, no data
    FMT_3DW_WD = 2'b10,   // 3 DW header, with data
    FMT_4DW_WD = 2'b11    // 4 DW header, with data
  } tlp_fmt_e;

  typedef enum bit [4:0] {
    TYPE_MEM   = 5'b00000,   // MRd / MWr  (distinguished by Fmt)
    TYPE_MEMLK = 5'b00001,
    TYPE_IO    = 5'b00010,
    TYPE_CFG0  = 5'b00100,
    TYPE_CFG1  = 5'b00101,
    TYPE_CPL   = 5'b01010,   // Cpl / CplD - what the DUT's RX path looks for
    TYPE_CPLLK = 5'b01011,
    TYPE_MSG   = 5'b10000
  } tlp_type_e;

  typedef enum bit [2:0] {
    CPL_SC  = 3'b000,   // Successful Completion
    CPL_UR  = 3'b001,   // Unsupported Request
    CPL_CRS = 3'b010,   // Configuration Request Retry Status
    CPL_CA  = 3'b100    // Completer Abort
  } cpl_status_e;

  localparam int unsigned TLP_MAX_DW = 4 + 1024;   // 4 DW header + 4 KiB payload

  //-------------------------------------------------------------------------
  // openpcie_tlp
  //-------------------------------------------------------------------------
  class openpcie_tlp extends uvm_object;

    rand tlp_fmt_e     fmt;
    rand tlp_type_e    ttype;
    rand bit [2:0]     tc;
    rand bit           td;
    rand bit           ep;
    rand bit [1:0]     attr;
    rand bit [9:0]     length;      // in DW; 0 encodes 1024 DW

    // DW1 - request flavour
    rand bit [15:0]    requester_id;
    rand bit [7:0]     tag;
    rand bit [3:0]     first_be;
    rand bit [3:0]     last_be;

    // DW1/DW2 - completion flavour
    rand bit [15:0]    completer_id;
    rand cpl_status_e  cpl_status;
    rand bit           bcm;
    rand bit [11:0]    byte_count;
    rand bit [6:0]     lower_addr;

    // DW2/DW3 - address
    rand bit [63:0]    address;

    rand bit [31:0]    payload[];

    `uvm_object_utils_begin(openpcie_tlp)
      `uvm_field_enum(tlp_fmt_e,  fmt,          UVM_ALL_ON)
      `uvm_field_enum(tlp_type_e, ttype,        UVM_ALL_ON)
      `uvm_field_int (tc,                       UVM_ALL_ON)
      `uvm_field_int (td,                       UVM_ALL_ON)
      `uvm_field_int (ep,                       UVM_ALL_ON)
      `uvm_field_int (attr,                     UVM_ALL_ON)
      `uvm_field_int (length,                   UVM_ALL_ON)
      `uvm_field_int (requester_id,             UVM_ALL_ON)
      `uvm_field_int (tag,                      UVM_ALL_ON)
      `uvm_field_int (first_be,                 UVM_ALL_ON)
      `uvm_field_int (last_be,                  UVM_ALL_ON)
      `uvm_field_int (completer_id,             UVM_ALL_ON)
      `uvm_field_enum(cpl_status_e, cpl_status, UVM_ALL_ON)
      `uvm_field_int (byte_count,               UVM_ALL_ON)
      `uvm_field_int (lower_addr,               UVM_ALL_ON)
      `uvm_field_int (address,                  UVM_ALL_ON)
      `uvm_field_array_int(payload,             UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "openpcie_tlp");
      super.new(name);
    endfunction

    // -- constraints ----------------------------------------------------
    constraint c_payload_matches_fmt {
      (fmt == FMT_3DW_WD || fmt == FMT_4DW_WD) -> payload.size() == length;
      (fmt == FMT_3DW_ND || fmt == FMT_4DW_ND) -> payload.size() == 0;
    }

    // Tier 1's bridge only ever emits a 3 DW header plus at most one payload
    // DW (riscv_pcie_soc.sv:195-211), so the default profile stays there.
    // Sequences targeting Tier 2 relax this.
    constraint c_tier1_shape {
      soft fmt inside {FMT_3DW_ND, FMT_3DW_WD};
      soft length inside {[1:1]};
    }

    constraint c_reserved_clean {
      soft tc   == 3'b000;
      soft attr == 2'b00;
      soft td   == 1'b0;
      soft ep   == 1'b0;
    }

    constraint c_addr_aligned { address[1:0] == 2'b00; }

    constraint c_be_sane {
      soft first_be == 4'hF;
      (length == 1) -> last_be == 4'h0;
      soft (length > 1) -> last_be == 4'hF;
    }

    // -- derived --------------------------------------------------------
    function bit has_data();
      return fmt[1];                       // Fmt[1] == DW0 bit 30
    endfunction

    function int unsigned hdr_dw();
      return fmt[0] ? 4 : 3;               // Fmt[0] selects 4 DW header
    endfunction

    function int unsigned total_dw();
      return hdr_dw() + payload.size();
    endfunction

    function bit is_completion();
      return (ttype == TYPE_CPL) || (ttype == TYPE_CPLLK);
    endfunction

    // -- header encode --------------------------------------------------
    function bit [31:0] dw0();
      return {1'b0, fmt, ttype, 1'b0, tc, 4'b0, td, ep, attr, 2'b00, length};
    endfunction

    function bit [31:0] dw1();
      if (is_completion())
        return {completer_id, cpl_status, bcm, byte_count};
      return {requester_id, tag, last_be, first_be};
    endfunction

    function bit [31:0] dw2();
      if (is_completion())
        return {requester_id, tag, 1'b0, lower_addr};
      if (fmt[0])                          // 4 DW header -> upper address
        return address[63:32];
      return {address[31:2], 2'b00};
    endfunction

    function bit [31:0] dw3();
      return {address[31:2], 2'b00};       // 4 DW header only
    endfunction

    function void pack_dw(output bit [31:0] dws[]);
      int unsigned n = total_dw();
      dws = new[n];
      dws[0] = dw0();
      dws[1] = dw1();
      dws[2] = dw2();
      if (fmt[0]) dws[3] = dw3();
      foreach (payload[i]) dws[hdr_dw() + i] = payload[i];
    endfunction

    // -- header decode --------------------------------------------------
    function void unpack_dw(const ref bit [31:0] dws[]);
      if (dws.size() < 3) begin
        `uvm_error("TLP/UNPACK", $sformatf(
          "need at least 3 DW to decode a TLP, got %0d", dws.size()))
        return;
      end
      fmt    = tlp_fmt_e'(dws[0][30:29]);
      ttype  = tlp_type_e'(dws[0][28:24]);
      tc     = dws[0][22:20];
      td     = dws[0][15];
      ep     = dws[0][14];
      attr   = dws[0][13:12];
      length = dws[0][9:0];

      if (is_completion()) begin
        completer_id = dws[1][31:16];
        cpl_status   = cpl_status_e'(dws[1][15:13]);
        bcm          = dws[1][12];
        byte_count   = dws[1][11:0];
        requester_id = dws[2][31:16];
        tag          = dws[2][15:8];
        lower_addr   = dws[2][6:0];
      end
      else begin
        requester_id = dws[1][31:16];
        tag          = dws[1][15:8];
        last_be      = dws[1][7:4];
        first_be     = dws[1][3:0];
        address      = fmt[0] ? {dws[2], dws[3]} : {32'h0, dws[2]};
      end

      begin
        int unsigned n = dws.size() - hdr_dw();
        payload = new[has_data() ? n : 0];
        foreach (payload[i]) payload[i] = dws[hdr_dw() + i];
      end
    endfunction

    // -- 64-bit AXI4-Stream beat conversion ------------------------------
    // Beats are little-endian DW-packed: beat[k] = {DW(2k+1), DW(2k)}.
    function void to_beats(output bit [63:0] data[], output bit [7:0] keep[]);
      bit [31:0] dws[];
      int unsigned nb;
      pack_dw(dws);
      nb = (dws.size() + 1) / 2;
      data = new[nb];
      keep = new[nb];
      foreach (data[i]) begin
        bit [31:0] lo = dws[2*i];
        bit [31:0] hi = (2*i + 1 < dws.size()) ? dws[2*i + 1] : 32'h0;
        data[i] = {hi, lo};
        keep[i] = (2*i + 1 < dws.size()) ? 8'hFF : 8'h0F;
      end
    endfunction

    function void from_beats(const ref bit [63:0] data[], const ref bit [7:0] keep[]);
      bit [31:0] dws[$];
      foreach (data[i]) begin
        if (keep[i][3:0] == 4'hF) dws.push_back(data[i][31:0]);
        if (keep[i][7:4] == 4'hF) dws.push_back(data[i][63:32]);
      end
      begin
        bit [31:0] arr[] = new[dws.size()];
        foreach (arr[i]) arr[i] = dws[i];
        unpack_dw(arr);
      end
    endfunction

    function string convert2string();
      string s = $sformatf("%s%s len=%0d",
                           ttype.name(), has_data() ? "/D" : "", length);
      if (is_completion())
        s = {s, $sformatf(" cpl=%s cid=%04h tag=%02h bc=%0d",
                          cpl_status.name(), completer_id, tag, byte_count)};
      else
        s = {s, $sformatf(" addr=%08h rid=%04h tag=%02h be=%1h/%1h",
                          address[31:0], requester_id, tag, first_be, last_be)};
      foreach (payload[i]) s = {s, $sformatf(" d%0d=%08h", i, payload[i])};
      return s;
    endfunction

  endclass

endpackage

`endif // OPENPCIE_TLP_PKG_SV
