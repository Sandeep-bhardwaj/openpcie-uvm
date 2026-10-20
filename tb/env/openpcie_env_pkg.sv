//---------------------------------------------------------------------------
// openpcie_env_pkg - Tier 1 environment, RAL and virtual sequence library
//---------------------------------------------------------------------------
// Include order matters: the mailbox is referenced by the RAL frontdoor, the
// RAL and predictor by the env, and the vseqr by the sequences.
//---------------------------------------------------------------------------

`ifndef OPENPCIE_ENV_PKG_SV
`define OPENPCIE_ENV_PKG_SV

package openpcie_env_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import openpcie_types_pkg::*;
  import openpcie_tlp_pkg::*;
  import openpcie_axis_pkg::*;
  import openpcie_cfg_pkg::*;
  import openpcie_cpu_pkg::*;

  // -- infrastructure ---------------------------------------------------
  `include "openpcie_fw_mailbox.svh"
  `include "openpcie_ral.svh"

  // -- analysis ---------------------------------------------------------
  `include "openpcie_predictor.svh"
  `include "openpcie_scoreboard.svh"
  `include "openpcie_soc_coverage.svh"

  // -- environment ------------------------------------------------------
  `include "openpcie_env_cfg.svh"
  `include "openpcie_vseqr.svh"
  `include "openpcie_env.svh"

  // -- stimulus ---------------------------------------------------------
  `include "openpcie_base_vseq.svh"
  `include "openpcie_vseq_lib.svh"

endpackage

`endif // OPENPCIE_ENV_PKG_SV
