//-----------------------------------------------------------------------------
// tb.f - testbench sources for the Tier 1 environment (DUT = riscv_pcie_soc)
//-----------------------------------------------------------------------------
// Compile order matters:
//   1. interfaces          openpcie_types_pkg typedefs virtual handles to them
//   2. common packages     types first, then the TLP model
//   3. agent packages      each one imports openpcie_types_pkg
//   4. environment package imports every agent
//   5. test package        imports the environment
//   6. assertion modules   no package dependencies
//   7. bind file           needs the bound interfaces and openpcie_soc_sva
//   8. tb_top              needs everything above
//
// ${OPENPCIE_ROOT} is the repository root (set by sim/Makefile and
// scripts/run.py).
//-----------------------------------------------------------------------------

// include paths
+incdir+${OPENPCIE_ROOT}/tb/common
+incdir+${OPENPCIE_ROOT}/tb/agents/axis_agent
+incdir+${OPENPCIE_ROOT}/tb/agents/cfg_agent
+incdir+${OPENPCIE_ROOT}/tb/agents/cpu_agent
+incdir+${OPENPCIE_ROOT}/tb/ral
+incdir+${OPENPCIE_ROOT}/tb/env
+incdir+${OPENPCIE_ROOT}/tb/seq
+incdir+${OPENPCIE_ROOT}/tb/tests
+incdir+${OPENPCIE_ROOT}/tb/sva
+incdir+${OPENPCIE_ROOT}/tb/top

// 1. interfaces
${OPENPCIE_ROOT}/tb/agents/axis_agent/openpcie_axis_if.sv
${OPENPCIE_ROOT}/tb/agents/cfg_agent/openpcie_cfg_if.sv
${OPENPCIE_ROOT}/tb/agents/cpu_agent/openpcie_cpu_if.sv
${OPENPCIE_ROOT}/tb/top/openpcie_rst_if.sv
${OPENPCIE_ROOT}/tb/top/openpcie_ram_bkdr_if.sv

// 2. common packages
${OPENPCIE_ROOT}/tb/common/openpcie_types_pkg.sv
${OPENPCIE_ROOT}/tb/common/openpcie_tlp_pkg.sv

// 3. agents
${OPENPCIE_ROOT}/tb/agents/axis_agent/openpcie_axis_pkg.sv
${OPENPCIE_ROOT}/tb/agents/cfg_agent/openpcie_cfg_pkg.sv
${OPENPCIE_ROOT}/tb/agents/cpu_agent/openpcie_cpu_pkg.sv

// 4. environment
${OPENPCIE_ROOT}/tb/env/openpcie_env_pkg.sv

// 5. tests
${OPENPCIE_ROOT}/tb/tests/openpcie_test_pkg.sv

// 6. assertions
${OPENPCIE_ROOT}/tb/sva/openpcie_axis_sva.sv
${OPENPCIE_ROOT}/tb/sva/openpcie_soc_sva.sv

// 7. bind
${OPENPCIE_ROOT}/tb/top/openpcie_bind.sv

// 8. top
${OPENPCIE_ROOT}/tb/top/tb_top.sv
