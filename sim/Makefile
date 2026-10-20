###############################################################################
# openPCIE UVM - Tier 1 regression driver
#
#   make                              smoke test on VCS
#   make TEST=openpcie_random_test    a specific test
#   make SIM=xcelium TEST=...         switch simulator
#   make SEED=1234 WAVES=1 VERB=UVM_HIGH
#   make regress                      full suite, one seed each
#   make regress SEEDS=5              full suite, 5 seeds each
#   make cov-report                   merge and report coverage
#   make clean / make distclean
#
# Every run happens in its own directory under build/run/, so parallel runs
# and per-seed logs never collide.
###############################################################################

SHELL          := /bin/bash
.DEFAULT_GOAL  := smoke

# ---- paths ------------------------------------------------------------------
SIM_DIR        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OPENPCIE_ROOT  := $(abspath $(SIM_DIR)/..)
export OPENPCIE_ROOT

BUILD_DIR      := $(OPENPCIE_ROOT)/build
FW_DIR         := $(OPENPCIE_ROOT)/tb/fw
FW_HEX         := $(BUILD_DIR)/fw/firmware.hex
RUN_ROOT       := $(BUILD_DIR)/run
COV_ROOT       := $(BUILD_DIR)/cov

PYTHON         ?= python

# ---- knobs ------------------------------------------------------------------
SIM            ?= vcs
TEST           ?= openpcie_smoke_test
SEED           ?= 1
VERB           ?= UVM_MEDIUM
WAVES          ?= 0
COV            ?= 0
UVM_HOME       ?=
GUI            ?= 0

# Extra options appended to compile/run, e.g. make SIMOPTS=+define+FOO
SIMOPTS        ?=
RUNOPTS        ?=

RUN_DIR        := $(RUN_ROOT)/$(TEST)_$(SEED)
LOG            := $(RUN_DIR)/sim.log

PLUSARGS        = +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB)
ifeq ($(WAVES),1)
PLUSARGS       += +WAVES
endif

# ---- file lists -------------------------------------------------------------
RTL_F          := $(SIM_DIR)/rtl.f
DV_F           := $(SIM_DIR)/tb.f

###############################################################################
# Firmware
###############################################################################
.PHONY: fw
fw: $(FW_HEX)

$(FW_HEX): $(FW_DIR)/mailbox_fw.s $(FW_DIR)/rv32.py $(FW_DIR)/build_fw.py
	@echo "=== building and self-testing PicoRV32 mailbox firmware ==="
	@$(PYTHON) $(FW_DIR)/build_fw.py

###############################################################################
# RTL patch layer
###############################################################################
.PHONY: patch-rtl list-patches lint

# 2.rtl/ is upstream's RTL and is never edited. Simulation compiles
# build/rtl_patched/, which carries the documented fixes the design needs in
# order to elaborate. 'make list-patches' explains each one.
#
# FIXES=1 additionally applies the OPTIONAL functional fixes - use it to watch
# the tests that currently fail on a real DUT defect go green. Left off by
# default so the default run still reports the finding.
FIXES ?= 0
ifeq ($(FIXES),1)
PATCH_ARGS = --with-fixes
# The predictor models the fixed write decode when the RTL carries the fixes.
SIMOPTS   += +define+OPENPCIE_RTL_FIXES
endif

patch-rtl:
	@$(PYTHON) $(OPENPCIE_ROOT)/scripts/rtl_patches.py $(PATCH_ARGS)

list-patches:
	@$(PYTHON) $(OPENPCIE_ROOT)/scripts/rtl_patches.py --list

# Static consistency checks that need no simulator: filelist and `include
# resolution, DUT port list vs tb_top, mailbox and register constants agreeing
# across the firmware, the types package and the RAL.  Cheap, and it catches
# the mistakes that otherwise cost a full compile round trip.
lint:
	@$(PYTHON) $(OPENPCIE_ROOT)/scripts/check_tb.py
	@$(PYTHON) $(OPENPCIE_ROOT)/scripts/tx_fsm_model.py -n 500 --seeds 2 \
	   | tail -6

# Real parse + elaborate with the slang front end (pyslang). Catches the
# overwhelming majority of first-compile failures without VCS/Xcelium.
# Needs a UVM source tree: set UVM_HOME, else the tb tier is skipped.
.PHONY: slang
slang:
	@$(PYTHON) $(OPENPCIE_ROOT)/scripts/slang_check.py

###############################################################################
# VCS
###############################################################################
VCS_COMP_OPTS  = -full64 -sverilog -timescale=1ns/1ps \
                 -ntb_opts uvm-1.2 \
                 +define+VCS \
                 -debug_access+r+w+nomemcbk \
                 -assert svaext \
                 -lca \
                 -CFLAGS -O2 \
                 -f $(RTL_F) -f $(DV_F) \
                 -l $(RUN_DIR)/compile.log \
                 -o $(RUN_DIR)/simv

VCS_RUN_OPTS   = +ntb_random_seed=$(SEED) $(PLUSARGS) -l $(LOG)

ifeq ($(COV),1)
VCS_COMP_OPTS += -cm line+cond+fsm+tgl+branch+assert \
                 -cm_dir $(COV_ROOT)/$(TEST)_$(SEED).vdb
VCS_RUN_OPTS  += -cm line+cond+fsm+tgl+branch+assert \
                 -cm_dir $(COV_ROOT)/$(TEST)_$(SEED).vdb \
                 -cm_name $(TEST)_$(SEED)
endif

ifeq ($(WAVES),1)
VCS_COMP_OPTS += -debug_access+all -kdb
endif

.PHONY: vcs
vcs: prep
	@echo "=== VCS compile: $(TEST) (seed $(SEED)) ==="
	cd $(RUN_DIR) && vcs $(VCS_COMP_OPTS) $(SIMOPTS)
	@echo "=== VCS run ==="
	cd $(RUN_DIR) && ./simv $(VCS_RUN_OPTS) $(RUNOPTS)
	@$(MAKE) --no-print-directory verdict

###############################################################################
# Xcelium
###############################################################################
XRUN_OPTS      = -64bit -sv -timescale 1ns/1ps \
                 -uvmhome CDNS-1.2 \
                 -access +rwc \
                 -assert_count_traces \
                 +define+XCELIUM \
                 -f $(RTL_F) -f $(DV_F) \
                 -top tb_top \
                 -svseed $(SEED) \
                 -l $(LOG) \
                 $(PLUSARGS)

ifeq ($(COV),1)
XRUN_OPTS     += -coverage all \
                 -covoverwrite \
                 -covworkdir $(COV_ROOT) \
                 -covtest $(TEST)_$(SEED)
endif

ifeq ($(GUI),1)
XRUN_OPTS     += -gui
endif

.PHONY: xcelium
xcelium: prep
	@echo "=== Xcelium elaborate + run: $(TEST) (seed $(SEED)) ==="
	cd $(RUN_DIR) && xrun $(XRUN_OPTS) $(SIMOPTS) $(RUNOPTS)
	@$(MAKE) --no-print-directory verdict

###############################################################################
# Common
###############################################################################
.PHONY: prep
prep: fw patch-rtl lint
	@mkdir -p $(RUN_DIR) $(COV_ROOT)
	@cp -f $(FW_HEX) $(RUN_DIR)/firmware.hex
	@echo "run directory: $(RUN_DIR)"

# The UVM report server prints a PASSED/FAILED banner; make the shell exit
# code agree with it so CI does not need to parse logs itself.
.PHONY: verdict
verdict:
	@if grep -q "TEST PASSED" $(LOG) 2>/dev/null; then \
	   echo "RESULT: PASS  ($(TEST), seed $(SEED))"; \
	 else \
	   echo "RESULT: FAIL  ($(TEST), seed $(SEED))  -- see $(LOG)"; \
	   grep -E "UVM_(ERROR|FATAL)" $(LOG) 2>/dev/null | head -20; \
	   exit 1; \
	 fi

.PHONY: run smoke
run:
	@$(MAKE) --no-print-directory $(SIM) TEST=$(TEST) SEED=$(SEED)

smoke:
	@$(MAKE) --no-print-directory $(SIM) TEST=openpcie_smoke_test SEED=$(SEED)

###############################################################################
# Regression
###############################################################################
TESTS ?= openpcie_smoke_test            \
         openpcie_tx_directed_test      \
         openpcie_tx_random_test        \
         openpcie_tx_backpressure_test  \
         openpcie_tx_slow_sink_test     \
         openpcie_tx_burst_sink_test    \
         openpcie_rx_cpl_test           \
         openpcie_reg_access_test       \
         openpcie_sideband_test         \
         openpcie_reset_test            \
         openpcie_random_test

SEEDS ?= 1

.PHONY: regress
regress: fw patch-rtl lint
	@rm -f $(BUILD_DIR)/regress.summary
	@pass=0; fail=0; \
	 for t in $(TESTS); do \
	   for s in $$(seq 1 $(SEEDS)); do \
	     printf "%-34s seed %-4s " $$t $$s; \
	     if $(MAKE) --no-print-directory $(SIM) TEST=$$t SEED=$$s COV=$(COV) \
	          > $(RUN_ROOT)/$$t\_$$s.mk.log 2>&1; then \
	       echo "PASS"; pass=$$((pass+1)); \
	       echo "PASS $$t $$s" >> $(BUILD_DIR)/regress.summary; \
	     else \
	       echo "FAIL"; fail=$$((fail+1)); \
	       echo "FAIL $$t $$s" >> $(BUILD_DIR)/regress.summary; \
	     fi; \
	   done; \
	 done; \
	 echo ""; \
	 echo "=================================================="; \
	 echo "  regression: $$pass passed, $$fail failed"; \
	 echo "  summary   : $(BUILD_DIR)/regress.summary"; \
	 echo "=================================================="; \
	 test $$fail -eq 0

###############################################################################
# Coverage
###############################################################################
.PHONY: cov-report
cov-report:
ifeq ($(SIM),vcs)
	urg -full64 -dir $(COV_ROOT)/*.vdb -report $(COV_ROOT)/urgReport
	@echo "coverage report: $(COV_ROOT)/urgReport/dashboard.html"
else
	imc -execcmd "load -run $(COV_ROOT)/*; report -summary -out $(COV_ROOT)/report.txt"
	@echo "coverage report: $(COV_ROOT)/report.txt"
endif

###############################################################################
# Housekeeping
###############################################################################
.PHONY: list clean distclean help
list:
	@echo "Available tests:"
	@for t in $(TESTS); do echo "  $$t"; done

clean:
	rm -rf $(RUN_ROOT) csrc simv* ucli.key vc_hdrs.h .vcs* \
	       xcelium.d xrun.history xrun.log INCA_libs waves.* \
	       $(BUILD_DIR)/regress.summary

distclean: clean
	rm -rf $(BUILD_DIR)

help:
	@sed -n '3,20p' $(lastword $(MAKEFILE_LIST))
