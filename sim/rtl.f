//-----------------------------------------------------------------------------
// rtl.f - design sources for Tier 1 (riscv_pcie_soc and its PicoRV32)
//-----------------------------------------------------------------------------
// The files come from build/rtl_patched/, which scripts/rtl_patches.py
// generates from the openPCIE submodule (rtl/openPCIE). The submodule itself
// is never edited. The generated copy carries one change the design needs in
// order to elaborate at all:
//
//   RTL-SIM-001  riscv_pcie_soc.sv writes `ram` from both an initial
//                $readmemh and an always_ff, which IEEE 1800-2017 9.2.2.4
//                does not allow. VCS rejects it with Error-[ICPD].
//
// 'python scripts/rtl_patches.py --list' prints every patch and its reason.
//
// Nothing here instantiates a Xilinx primitive, so Tier 1 elaborates without
// the unisim/secureip libraries.
//-----------------------------------------------------------------------------

${OPENPCIE_ROOT}/build/rtl_patched/picorv32.v
${OPENPCIE_ROOT}/build/rtl_patched/riscv_pcie_soc.sv
