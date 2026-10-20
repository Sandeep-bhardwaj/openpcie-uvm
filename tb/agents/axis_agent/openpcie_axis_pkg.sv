//---------------------------------------------------------------------------
// openpcie_axis_pkg - AXI4-Stream UVM agent
//---------------------------------------------------------------------------

`ifndef OPENPCIE_AXIS_PKG_SV
`define OPENPCIE_AXIS_PKG_SV

package openpcie_axis_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import openpcie_types_pkg::*;

  `include "openpcie_axis_item.svh"
  `include "openpcie_axis_cfg.svh"
  `include "openpcie_axis_driver.svh"
  `include "openpcie_axis_responder.svh"
  `include "openpcie_axis_monitor.svh"
  `include "openpcie_axis_coverage.svh"
  `include "openpcie_axis_agent.svh"

endpackage

`endif // OPENPCIE_AXIS_PKG_SV
