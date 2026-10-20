//---------------------------------------------------------------------------
// openpcie_axis_item - one AXI4-Stream packet (tvalid..tlast)
//---------------------------------------------------------------------------
// The item is packet-granular rather than beat-granular so that sequences
// speak in TLPs and the scoreboard compares whole packets.  Per-beat timing is
// still controllable through `pre_beat_delay`, which is what lets a test walk
// a stall across every beat boundary.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_ITEM_SVH
`define OPENPCIE_AXIS_ITEM_SVH

class openpcie_axis_item extends uvm_sequence_item;

  rand bit [AXIS_DATA_W-1:0] data[];
  rand bit [AXIS_KEEP_W-1:0] keep[];
  rand bit [AXIS_USER_W-1:0] user[];

  // Idle cycles inserted before each beat is offered (master role only).
  rand int unsigned pre_beat_delay[];

  // Idle cycles between the end of this packet and the next.
  rand int unsigned inter_packet_gap;

  // Set by the monitor; ignored by the driver.
  time     t_start;
  time     t_end;
  int      beats_observed;
  bit      saw_reset;      // packet was truncated by reset
  bit      is_last;        // beat-level publishes only: this beat had tlast

  `uvm_object_utils_begin(openpcie_axis_item)
    `uvm_field_array_int(data,             UVM_ALL_ON)
    `uvm_field_array_int(keep,             UVM_ALL_ON)
    `uvm_field_array_int(user,             UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_field_array_int(pre_beat_delay,   UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_field_int      (inter_packet_gap, UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_field_int      (beats_observed,   UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_field_int      (saw_reset,        UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_field_int      (is_last,          UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "openpcie_axis_item");
    super.new(name);
  endfunction

  constraint c_sizes {
    data.size() inside {[1:64]};
    keep.size()           == data.size();
    user.size()           == data.size();
    pre_beat_delay.size() == data.size();
  }

  // Only the last beat of a packed stream may carry a partial tkeep, and a
  // partial tkeep must still be a contiguous run from bit 0.
  constraint c_keep_packed {
    foreach (keep[i]) {
      if (i < data.size() - 1) keep[i] == '1;
      else                     keep[i] inside {8'h0F, 8'hFF};
    }
  }

  constraint c_delays {
    foreach (pre_beat_delay[i]) soft pre_beat_delay[i] inside {[0:3]};
    soft inter_packet_gap inside {[0:8]};
  }

  function int unsigned n_beats();
    return data.size();
  endfunction

  // Total valid bytes across the packet.
  function int unsigned n_bytes();
    int unsigned n = 0;
    foreach (keep[i])
      for (int b = 0; b < AXIS_KEEP_W; b++) n += keep[i][b];
    return n;
  endfunction

  function string convert2string();
    string s = $sformatf("AXIS pkt: %0d beat(s), %0d byte(s)",
                         n_beats(), n_bytes());
    foreach (data[i])
      s = {s, $sformatf("\n  [%02d] data=%016h keep=%02h user=%01h",
                        i, data[i], keep[i], user[i])};
    return s;
  endfunction

endclass

`endif // OPENPCIE_AXIS_ITEM_SVH
