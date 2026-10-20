#!/usr/bin/env python3
"""
Generate docs/testplan.xlsx, the Tier 1 verification tracking workbook.

    python scripts/gen_testplan_xlsx.py            # write docs/testplan.xlsx
    python scripts/gen_testplan_xlsx.py -o out.xlsx

Sheets: Summary, Features, Test Cases, Traceability, Coverage, Checkers,
Findings, Regression. The data below mirrors docs/verification_plan.md and
docs/testplan.md; update both when a requirement, test or result changes.
Summary figures are formulas over the other sheets, so editing a status or a
result in Excel updates them. Needs openpyxl.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from openpyxl import Workbook
from openpyxl.formatting.rule import CellIsRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.workbook.properties import CalcProperties
from openpyxl.worksheet.datavalidation import DataValidation

ROOT = Path(__file__).resolve().parent.parent
_ap = argparse.ArgumentParser(description="Generate the testplan workbook.")
_ap.add_argument("-o", "--out", type=Path, default=ROOT / "docs" / "testplan.xlsx")
OUT = _ap.parse_args().out

F = "Arial"
HDR_FILL = PatternFill("solid", fgColor="1F3864")
HDR_FONT = Font(name=F, bold=True, color="FFFFFF", size=10)
BODY = Font(name=F, size=10)
BOLD = Font(name=F, size=10, bold=True)
TITLE = Font(name=F, size=14, bold=True, color="1F3864")
EDIT_FILL = PatternFill("solid", fgColor="FFF2CC")   # user-editable cells
THIN = Side(style="thin", color="BFBFBF")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
WRAP = Alignment(wrap_text=True, vertical="top")
CENTER = Alignment(horizontal="center", vertical="top", wrap_text=True)

GREEN = PatternFill("solid", fgColor="C6EFCE")
RED = PatternFill("solid", fgColor="FFC7CE")
AMBER = PatternFill("solid", fgColor="FFEB9C")


def table(ws, row, headers, rows, widths, edit_cols=(), center_cols=()):
    for c, h in enumerate(headers, 1):
        cell = ws.cell(row=row, column=c, value=h)
        cell.font, cell.fill, cell.border = HDR_FONT, HDR_FILL, BOX
        cell.alignment = Alignment(wrap_text=True, vertical="center",
                                   horizontal="center")
    for r, data in enumerate(rows, row + 1):
        for c, v in enumerate(data, 1):
            cell = ws.cell(row=r, column=c, value=v)
            cell.font, cell.border = BODY, BOX
            cell.alignment = CENTER if c in center_cols else WRAP
            if c in edit_cols:
                cell.fill = EDIT_FILL
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = ws.cell(row=row + 1, column=1)
    ws.auto_filter.ref = (f"A{row}:{get_column_letter(len(headers))}"
                          f"{row + len(rows)}")
    return row + 1, row + len(rows)


def status_format(ws, rng):
    ws.conditional_formatting.add(rng, CellIsRule(operator="equal",
                                  formula=['"Pass"'], fill=GREEN))
    ws.conditional_formatting.add(rng, CellIsRule(operator="equal",
                                  formula=['"Fail"'], fill=RED))
    for s in ('"Fail (expected)"', '"Partial"', '"Open"', '"Not run"'):
        ws.conditional_formatting.add(rng, CellIsRule(operator="equal",
                                      formula=[s], fill=AMBER))
    for s in ('"Met"', '"Verified"', '"Closed"', '"Fixed"'):
        ws.conditional_formatting.add(rng, CellIsRule(operator="equal",
                                      formula=[s], fill=GREEN))


wb = Workbook()

# ---------------------------------------------------------------- Features
REQS = [
 ("SMOKE-001", "Firmware boots, mailbox handshake completes, one TLP traverses TX", "P1", "—", "Boot magic; scoreboard", "—", "TC-01"),
 ("TX-FMT-001", "3-DW header + 1 payload DW → 2 beats, final tkeep=0xFF", "P1", "riscv_pcie_soc.sv:195-211", "Predictor/scoreboard; SOC-003", "x_fmt_keep.ok_data_full", "TC-01, TC-02, TC-03"),
 ("TX-FMT-002", "3-DW header, no payload (Fmt[1]=0) → final tkeep=0x0F", "P1", ":204", "Predictor/scoreboard; SOC-003", "x_fmt_keep.ok_nodata_partial", "TC-02, TC-03"),
 ("TX-FMT-003", "First beat always tkeep=0xFF, tlast=0", "P1", ":197-199", "SOC-004, SOC-002", "cg_packet_t1", "All TX tests"),
 ("TX-DATA-001", "Beat 0 = {HDR1,HDR0}, beat 1 = {DATA,HDR2}; no bit stuck, swapped or dropped", "P1", ":196,203", "Scoreboard", "—", "TC-02"),
 ("TX-RAND-001", "All Tier 1 TLP kinds (MEM, IO, CFG0, CFG1, CPL) and Lengths 1–1024 framed correctly", "P1", ":195-211", "Scoreboard", "cg_tlp.cp_type, cp_len, x_type_fmt", "TC-03"),
 ("TX-TRIG-001", "Only a write to TX_DATA starts a transmit; header writes are inert", "P1", ":180-185", "Predictor; build_fw.py model", "—", "TC-08"),
 ("TX-TRIG-002", "Header registers are sticky across transmits", "P2", ":177-179", "Scoreboard", "—", "TC-08"),
 ("TX-PROTO-001", "tvalid held until tready", "P1", "AXI4-Stream §2.2.1", "AXIS-001", "c_stall*", "All TX tests"),
 ("TX-PROTO-002", "Payload stable while stalled", "P1", "AXI4-Stream §2.2.1", "AXIS-002, monitor", "c_stall_on_first/last", "TC-04, TC-05, TC-06, TC-11"),
 ("TX-PROTO-003", "tkeep contiguous; partial only on tlast", "P1", "AXI4-Stream Table 2-2", "AXIS-004/005", "cg_packet_t1", "All TX tests"),
 ("TX-PROTO-004", "Transmit survives backpressure without losing a beat", "P1", ":200,208", "AXIS-002 + scoreboard", "c_tx_stall_in_c1/c2", "TC-04, TC-05, TC-06, TC-11"),
 ("TX-FLOW-001", "Behaviour with tx_buf_av = 0 documented (DUT does not gate on credits)", "P3", ":153", "Directed readback", "c_tx_while_no_credit, cp_tx_buf_av.empty", "TC-09"),
 ("TX-FLOW-002", "Software must poll tx_state==IDLE before each send (no HW interlock)", "P3", ":180-185", "Documented contract", "—", "—"),
 ("RX-CAP-001", "Completion status captured from tdata[47:45]", "P1", ":217-219", "Readback vs predictor", "cg_reg_access", "TC-07"),
 ("RX-CAP-002", "Phase 1 captures DW2 → RX_HDR_INFO, DW3 → RX_DATA", "P1", ":223-224", "Readback vs predictor", "cg_reg_access", "TC-07"),
 ("RX-CAP-003", "A non-completion inbound TLP leaves capture registers unchanged", "P2", ":217", "Predictor mirrors RTL", "—", "TC-07"),
 ("RX-CAP-004", "m_axis_rx_tready is tied high", "P2", ":233", "SOC-006", "—", "All"),
 ("REG-001", "All five readable registers decode correctly", "P1", ":243-249", "RAL + scoreboard", "x_offset_dir", "TC-08"),
 ("REG-002", "TX registers are write-only; reads return 0", "P1", ":248", "Directed check", "x_offset_dir", "TC-08"),
 ("REG-003", "Read decode aliases every 64 bytes", "P3", ":239-249", "Directed alias check", "cp_offset.aliased", "TC-08"),
 ("REG-004", "A write to a read-only register has no side effect", "P2", ":175", "Scoreboard packet compare", "x_offset_dir", "TC-08"),
 ("CFG-001", "ERR_STATUS = {err_fatal, cfg_status}", "P1", ":152", "Readback vs predictor", "cg_sideband", "TC-09"),
 ("CFG-002", "PHY_STATUS[5:0] tracks tx_buf_av", "P1", ":153", "Readback (masked)", "cp_tx_buf_av", "TC-09"),
 ("CFG-003", "cfg_command has no effect (port unused)", "P3", ":60", "SOC-010", "—", "TC-09"),
 ("RST-001", "Reset clears the RX capture registers and the TX FSM", "P1", ":157-167", "Directed readback", "—", "TC-10"),
 ("RST-002", "CPU re-boots and the datapath works after reset", "P1", "—", "Re-boot handshake + traffic", "—", "TC-10"),
 ("CPU-001", "PicoRV32 bus handshake is honoured by the bridge", "P2", ":172-173,256", "SOC-008/009/011", "—", "All"),
 ("MIX-001", "Sustained mixed traffic under random backpressure", "P1", "—", "Full environment", "All groups", "TC-11"),
]
# Verification status as of the latest run.
STATUS = {"TX-PROTO-004": ("Fail (expected)", "Fails on RTL as written; passes with fix 0002 (finding TX-PROTO-004)"),
          "REG-004": ("Fail (expected)", "Alias confirmed on RTL as written; fixed by patch 0003"),
          "TX-FLOW-002": ("Verified", "Documented software contract; no test")}

ws = wb.active
ws.title = "Features"
rows = []
for r in REQS:
    st, note = STATUS.get(r[0], ("Verified", ""))
    rows.append(list(r) + [st, note])
first_req, last_req = table(
    ws, 1,
    ["Req ID", "Requirement", "Priority", "RTL / spec reference", "Check mechanism",
     "Coverage item", "Test case(s)", "Status", "Notes"],
    rows, [14, 52, 9, 22, 28, 30, 22, 16, 44], edit_cols=(8, 9), center_cols=(3, 8))
dv = DataValidation(type="list", formula1='"Verified,Fail (expected),Partial,Open,Not run"', allow_blank=True)
ws.add_data_validation(dv)
dv.add(f"H{first_req}:H{last_req}")
dvp = DataValidation(type="list", formula1='"P1,P2,P3"')
ws.add_data_validation(dvp)
dvp.add(f"C{first_req}:C{last_req}")
status_format(ws, f"H{first_req}:H{last_req}")

# ---------------------------------------------------------------- Test Cases
TESTS = [
 ("TC-01", "openpcie_smoke_test", "openpcie_smoke_vseq", "D", "P1", "READY_ALWAYS", "2 ms",
  "SMOKE-001, TX-FMT-001",
  "Boot; one MemWr32 @0x1000_0000 (0xCAFE_BABE); sync; read PHY_STATUS, ERR_STATUS",
  "2-beat packet matched (final tkeep 0xFF); readbacks match predictor; SVA clean", "Pass", "Pass"),
 ("TC-02", "openpcie_tx_directed_test", "openpcie_tx_directed_vseq", "D", "P1", "READY_ALWAYS", "10 ms",
  "TX-FMT-001/002/003, TX-DATA-001",
  "3 MemWr32 (zero, all-ones, mixed); 2 MemRd32; 1 CplD; 32 MemWr32 walking-ones payload",
  "38 packets matched; tkeep 0xFF with payload, 0x0F without; SOC-003/004", "Pass", "Pass"),
 ("TC-03", "openpcie_tx_random_test", "openpcie_tx_random_vseq", "CR", "P1", "READY_ALWAYS", "20 ms",
  "TX-RAND-001, TX-FMT-001/002/003",
  "20–400 random TLPs: Fmt with/without data; MEM/IO/CFG0/CFG1/CPL; MEM reads Length 1–1024",
  "Scoreboard packet compare; SVA", "Pass", "Pass"),
 ("TC-04", "openpcie_tx_backpressure_test", "openpcie_tx_backpressure_vseq", "D/CR", "P1", "READY_RANDOM, 40 %", "20 ms",
  "TX-PROTO-001/002/004",
  "30–200 TLPs alternating MemWr32 / MemRd32 under random stalls",
  "AXIS-001/002, monitor stability, scoreboard; responder confirms stalls", "Fail (expected)", "Pass"),
 ("TC-05", "openpcie_tx_slow_sink_test", "openpcie_tx_backpressure_vseq", "D", "P1", "READY_SLOW, period 4", "20 ms",
  "TX-PROTO-001/002/004", "As TC-04, one beat accepted every 4 cycles", "As TC-04", "Fail (expected)", "Pass"),
 ("TC-06", "openpcie_tx_burst_sink_test", "openpcie_tx_backpressure_vseq", "D", "P1", "READY_BURST, 1 accept / 3 stall", "20 ms",
  "TX-PROTO-001/002/004", "As TC-04, alternating accept/stall runs", "As TC-04", "Fail (expected)", "Pass"),
 ("TC-07", "openpcie_rx_cpl_test", "openpcie_rx_cpl_vseq", "D/CR", "P1", "READY_ALWAYS; no TX required", "20 ms",
  "RX-CAP-001/002/003",
  "10–100 CplD cycling SC/UR/CRS/CA + readback of RX_STATUS/RX_DATA/RX_HDR_INFO; 4 Cpl without data; 1 inbound MemWr32",
  "Readbacks equal predictor shadow; RX_DATA unchanged after non-Cpl TLP", "Pass", "Pass"),
 ("TC-08", "openpcie_reg_access_test", "openpcie_reg_access_vseq", "D", "P1", "READY_ALWAYS; RAL built", "10 ms",
  "REG-001..004, TX-TRIG-001/002",
  "RAL read 5 RO regs; write TX_HDR0..2; read back WO regs; write all RO regs (MRd header to +0x20); RAL read again; write TX_DATA; read +0x14 vs +0x54",
  "WO reads 0; RO unchanged; packet = MRd (RTL as written) or MWr (fixed), predictor matches both; +0x54 aliases +0x14", "Pass", "Pass"),
 ("TC-09", "openpcie_sideband_test", "openpcie_sideband_vseq", "D", "P1", "READY_ALWAYS", "20 ms",
  "CFG-001/002/003, TX-FLOW-001",
  "tx_buf_av 32→0 with cfg_status 0/FFFF/0010, TLP + PHY_STATUS read each step; err_fatal with cfg_status A5A5; err_fatal at credits 16..0",
  "PHY_STATUS[5:0] = tx_buf_av; ERR_STATUS = {err_fatal, cfg_status}; TX continues at 0 credits; SOC-010", "Pass", "Pass"),
 ("TC-10", "openpcie_reset_test", "openpcie_reset_vseq", "D", "P1", "READY_ALWAYS", "20 ms",
  "RST-001/002",
  "8 MemWr32; reset pulse 20 cycles; wait re-boot; read RX_DATA, RX_STATUS; 8 MemWr32",
  "Firmware re-boots; RX regs read 0; post-reset packets match", "Pass", "Pass"),
 ("TC-11", "openpcie_random_test", "openpcie_random_vseq", "CR", "P1", "READY_RANDOM, 65 %", "60 ms",
  "MIX-001, TX-PROTO-004, all groups",
  "50–500 iterations: MemWr32 40 %, MemRd32 20 %, CplD out 10 %, CplD in 10 %, reg read 10 %, sideband change 10 %",
  "Full environment: scoreboard, predictor, monitor, all SVA", "Fail (expected)", "Pass"),
]
ws = wb.create_sheet("Test Cases")
first_tc, last_tc = table(
    ws, 1,
    ["TC ID", "UVM test", "Virtual sequence", "Type", "Priority", "Sink profile / config",
     "Timeout", "Requirements", "Stimulus", "Checks / expected result",
     "Result: RTL as written", "Result: with fixes", "Owner", "Comments"],
    [list(t) + ["", ""] for t in TESTS],
    [8, 28, 28, 7, 9, 22, 9, 24, 50, 46, 16, 14, 12, 30],
    edit_cols=(11, 12, 13, 14), center_cols=(1, 4, 5, 7, 11, 12))
dvr = DataValidation(type="list", formula1='"Pass,Fail,Fail (expected),Not run"', allow_blank=True)
ws.add_data_validation(dvr)
dvr.add(f"K{first_tc}:L{last_tc}")
status_format(ws, f"K{first_tc}:L{last_tc}")

# ---------------------------------------------------------------- Traceability
PRIMARY = {
 "SMOKE-001": "1", "TX-FMT-001": "123", "TX-FMT-002": "23", "TX-FMT-003": "23",
 "TX-DATA-001": "2", "TX-RAND-001": "3", "TX-TRIG-001": "8", "TX-TRIG-002": "8",
 "TX-PROTO-001": "456B", "TX-PROTO-002": "456B", "TX-PROTO-004": "456B",
 "TX-FLOW-001": "9", "RX-CAP-001": "7", "RX-CAP-002": "7", "RX-CAP-003": "7",
 "REG-001": "8", "REG-002": "8", "REG-003": "8", "REG-004": "8",
 "CFG-001": "9", "CFG-002": "9", "CFG-003": "9", "RST-001": "A", "RST-002": "A",
 "MIX-001": "B"}
ALSO = {
 "TX-FMT-001": "45689AB", "TX-FMT-002": "4568B", "TX-FMT-003": "145689AB",
 "TX-DATA-001": "3B", "TX-RAND-001": "B", "TX-PROTO-001": "12389A",
 "TX-PROTO-003": "123456789AB", "RX-CAP-001": "B", "RX-CAP-002": "B",
 "RX-CAP-004": "123456789AB", "REG-001": "1679AB", "CFG-001": "18B",
 "CFG-002": "18", "CFG-003": "B", "CPU-001": "123456789AB"}
KEYS = "123456789AB"
ws = wb.create_sheet("Traceability")
hdr = ["Req ID", "Priority"] + [f"TC-{i:02d}" for i in range(1, 12)] + ["Primary tests", "Total tests", "Covered?"]
trows = []
for i, r in enumerate(REQS):
    rid = r[0]
    marks = []
    for k in KEYS:
        if k in PRIMARY.get(rid, ""):
            marks.append("●")
        elif k in ALSO.get(rid, ""):
            marks.append("○")
        else:
            marks.append("")
    row = 2 + i
    trows.append([rid, r[2]] + marks + [
        f'=COUNTIF(C{row}:M{row},"●")',
        f'=COUNTIF(C{row}:M{row},"●")+COUNTIF(C{row}:M{row},"○")',
        f'=IF(A{row}="TX-FLOW-002","Doc only",IF(O{row}>0,"Yes","NO"))'])
first_tr, last_tr = table(ws, 1, hdr, trows, [14, 9] + [7] * 11 + [10, 10, 11],
                          center_cols=tuple(range(2, 17)))
ws.conditional_formatting.add(f"P{first_tr}:P{last_tr}", CellIsRule(operator="equal", formula=['"NO"'], fill=RED))
ws.conditional_formatting.add(f"P{first_tr}:P{last_tr}", CellIsRule(operator="equal", formula=['"Yes"'], fill=GREEN))
legend_r = last_tr + 2
ws.cell(row=legend_r, column=1, value="● primary target of the test   ○ also exercised and checked").font = BODY
ws.cell(row=legend_r + 1, column=1, value="Requirements per test (primary):").font = BOLD
ws.cell(row=legend_r + 2, column=1, value="Requirements per test (any):").font = BOLD
for c in range(3, 14):
    col = get_column_letter(c)
    a = ws.cell(row=legend_r + 1, column=c, value=f'=COUNTIF({col}{first_tr}:{col}{last_tr},"●")')
    b = ws.cell(row=legend_r + 2, column=c,
                value=f'=COUNTIF({col}{first_tr}:{col}{last_tr},"●")+COUNTIF({col}{first_tr}:{col}{last_tr},"○")')
    for x in (a, b):
        x.font, x.alignment, x.border = BODY, CENTER, BOX

# ---------------------------------------------------------------- Coverage
COV = [
 ("cg_reg_access", "offset (9 named + aliased), direction, offset × direction", 1, 0.852, 1.0, "openpcie_soc_coverage.svh"),
 ("cg_tlp", "Type, Fmt, Length, final tkeep, Fmt × tkeep, Type × Fmt", 1, 0.615, 1.0, "openpcie_soc_coverage.svh"),
 ("cg_sideband", "tx_buf_av, err_fatal, cfg_status, credit × err_fatal", 1, 0.563, 1.0, "openpcie_soc_coverage.svh"),
 ("cg_packet_t1 (tx, rx)", "2 beats; final tkeep 0x0F/0xFF; 12/16 bytes", 1, None, 1.0, "openpcie_axis_coverage.svh"),
 ("cg_packet (tx, rx)", "All packet shapes (kept for Tier 2)", 0, 0.241, 0.241, "openpcie_axis_coverage.svh"),
 ("cg_tlp_diag", "Non-conforming Fmt/tkeep pairs — must stay empty", 0, None, 0.0, "openpcie_soc_coverage.svh"),
]
ws = wb.create_sheet("Coverage")
ws["A1"] = "Functional coverage — Vivado 2026.1 xsim, merged over 55 runs on fixed RTL"
ws["A1"].font = TITLE
crow = []
for i, c in enumerate(COV):
    r = 4 + i
    crow.append([c[0], c[1], c[2], 1.0 if c[2] else "n/a", c[3] if c[3] is not None else "—", c[4],
                 f'=IF(C{r}=0,"Tracked (weight 0)",IF(F{r}>=D{r},"Met","Open"))', c[5]])
f0, l0 = table(ws, 3, ["Covergroup", "Coverpoints / crosses", "Weight", "Goal",
                        "2026-09-26", "Latest", "Status", "Source"],
               crow, [26, 56, 9, 9, 12, 12, 18, 28], edit_cols=(6,), center_cols=(3, 4, 5, 6, 7))
for r in range(f0, l0 + 1):
    for c in (4, 5, 6):
        ws.cell(row=r, column=c).number_format = "0.0%"
tot = l0 + 1
ws.cell(row=tot, column=1, value="Weighted score (weight-1 groups)").font = BOLD
ws.cell(row=tot, column=6, value=f"=SUMPRODUCT(C{f0}:C{l0},F{f0}:F{l0})/SUM(C{f0}:C{l0})")
ws.cell(row=tot, column=6).number_format = "0.0%"
ws.cell(row=tot, column=7, value=f'=IF(F{tot}>=0.95,"Met","Open")')
for c in (1, 6, 7):
    ws.cell(row=tot, column=c).border = BOX
    ws.cell(row=tot, column=c).font = BOLD
status_format(ws, f"G{f0}:G{tot}")
ws.cell(row=tot + 1, column=1,
        value="Note: cg_tlp_diag at 0 % is the passing outcome. The 2026-09-26 column is the "
              "pre-closure baseline (merged score 55.6 %). Sign-off goal: ≥ 95 %.").font = Font(name=F, size=9, italic=True)

r0 = tot + 4
ws.cell(row=r0 - 1, column=1, value="Assertion cover points (need VCS or Xcelium; xsim ignores cover property)").font = BOLD
COVP = ["c_stall", "c_stall_2cyc", "c_stall_5cyc", "c_stall_on_first", "c_stall_on_last",
        "c_btb_packets", "c_partial_last", "c_full_last", "c_tx_full_packet", "c_tx_stall_in_c1",
        "c_tx_stall_in_c2", "c_rx_phase_toggle", "c_credit_exhausted", "c_tx_while_no_credit"]
src = {c: "openpcie_axis_sva.sv" for c in COVP[:8]}
src.update({c: "openpcie_soc_sva.sv" for c in COVP[8:]})
for c, h in enumerate(["Cover point", "Source", "Hits", "Status"], 1):
    cell = ws.cell(row=r0, column=c, value=h)
    cell.font, cell.fill, cell.border = HDR_FONT, HDR_FILL, BOX
for i, cp in enumerate(COVP):
    r = r0 + 1 + i
    vals = [cp, src[cp], None, f'=IF(C{r}="","Not run",IF(C{r}>0,"Met","Open"))']
    for c, v in enumerate(vals, 1):
        cell = ws.cell(row=r, column=c, value=v)
        cell.font, cell.border = BODY, BOX
        if c == 3:
            cell.fill = EDIT_FILL
status_format(ws, f"D{r0 + 1}:D{r0 + len(COVP)}")

# ---------------------------------------------------------------- Assertions
SVA = [
 ("AXIS-001", "openpcie_axis_sva.sv", "tvalid stays high until tready", "TX-PROTO-001"),
 ("AXIS-002", "openpcie_axis_sva.sv", "tdata/tkeep/tlast stable while stalled", "TX-PROTO-002, TX-PROTO-004"),
 ("AXIS-003", "openpcie_axis_sva.sv", "A valid beat carries at least one byte", "TX-PROTO-003"),
 ("AXIS-004", "openpcie_axis_sva.sv", "tkeep contiguous from bit 0", "TX-PROTO-003"),
 ("AXIS-005", "openpcie_axis_sva.sv", "Only the last beat may be partial", "TX-PROTO-003"),
 ("AXIS-006", "openpcie_axis_sva.sv", "No X/Z on control or data while tvalid", "TX-PROTO-003"),
 ("AXIS-007", "openpcie_axis_sva.sv", "tvalid/tready never X out of reset", "TX-PROTO-001"),
 ("SOC-001", "openpcie_soc_sva.sv", "tx_state only takes legal encodings", "TX-FMT-003"),
 ("SOC-002", "openpcie_soc_sva.sv", "A packet is exactly two beats", "TX-FMT-003"),
 ("SOC-003", "openpcie_soc_sva.sv", "Final tkeep ∈ {0x0F, 0xFF} and agrees with Fmt[1]", "TX-FMT-001, TX-FMT-002"),
 ("SOC-004", "openpcie_soc_sva.sv", "First beat tkeep = 0xFF", "TX-FMT-003"),
 ("SOC-005", "openpcie_soc_sva.sv", "No tvalid while tx_state == IDLE", "TX-FMT-003"),
 ("SOC-006", "openpcie_soc_sva.sv", "m_axis_rx_tready tied high", "RX-CAP-004"),
 ("SOC-007", "openpcie_soc_sva.sv", "rx_phase never X/Z", "RX-CAP-002"),
 ("SOC-008", "openpcie_soc_sva.sv", "CPU request stable until mem_ready", "CPU-001"),
 ("SOC-009", "openpcie_soc_sva.sv", "mem_ready traceable to a request this or last cycle", "CPU-001"),
 ("SOC-010", "openpcie_soc_sva.sv", "cfg_command, cfg_status, tx_buf_av never X/Z", "CFG-003"),
 ("SOC-011", "openpcie_soc_sva.sv", "Trailing mem_ready pulse lasts at most one cycle", "CPU-001"),
 ("SCBD/TX", "openpcie_scoreboard.svh", "Observed TX packet equals predicted; no unexpected/missing packets", "TX-*"),
 ("SCBD/RD", "openpcie_scoreboard.svh", "Register readback equals predictor shadow", "REG-*, RX-CAP-*, CFG-*"),
 ("SCBD (EOT)", "openpcie_scoreboard.svh", "No leftovers; TX activity seen when required", "All"),
 ("AXIS/PROTO", "openpcie_axis_monitor.svh", "Handshake/stability rules needing packet history", "TX-PROTO-*"),
 ("FWBOX", "openpcie_fw_mailbox.svh", "Boot timeout, command timeout, mailbox handshake order", "SMOKE-001"),
]
ws = wb.create_sheet("Checkers")
srows = [[a, b, c, d, "Assertion" if a.startswith(("AXIS-", "SOC-")) else "Checker",
          "Fires (TX-PROTO-004)" if a in ("AXIS-002", "SCBD/TX", "AXIS/PROTO", "AXIS-001", "SOC-002") else "Clean",
          "Clean"] for a, b, c, d in SVA]
table(ws, 1, ["ID", "Source", "Property / check", "Requirement(s)", "Kind",
              "RTL as written", "With fixes"], srows, [13, 26, 58, 26, 11, 20, 12],
      center_cols=(5, 6, 7))

# ---------------------------------------------------------------- Findings
FIND = [
 ("TX-PROTO-004", "High", "TX FSM samples tready one cycle early; beat 0 is lost under backpressure",
  "riscv_pcie_soc.sv:195-211", "TC-04, TC-05, TC-06, TC-11", "Confirmed", "patches/0002-tx-fsm-honour-axis-handshake.patch", "Open"),
 ("REG-004", "Medium", "Register writes ignore addr[5]: write to PHY_STATUS overwrites TX_HDR0; write to +0x2C starts a transmit",
  ":175", "TC-08", "Confirmed", "patches/0003-bridge-write-decode-use-addr5.patch", "Open"),
 ("RTL-SIM-001", "Medium", "ram written by both $readmemh and always_ff; VCS will not elaborate",
  ":99-120", "all (compile)", "Confirmed", "patches/0001-ram-always-instead-of-always_ff.patch (applied by patch layer)", "Open"),
 ("CFG-003", "Low", "cfg_command input never read; unconnected at chip top", ":60", "TC-09", "Documented", "—", "Open"),
 ("RTL-SIM-002", "Low", "RAM path re-arms mem_ready for one extra cycle (benign)", ":106-120", "SOC-009/011", "Documented", "Optional: && !ram_ready_reg", "Open"),
 ("TX-FLOW-002", "Info", "No HW busy interlock on TX_DATA; software must poll tx_state", ":180-185", "—", "Documented", "—", "Closed"),
 ("REG-003", "Info", "Read decode aliases every 64 bytes", ":239-249", "TC-08", "Documented", "—", "Closed"),
 ("RX-CAP-003", "Info", "RX capture FSM cannot resynchronise to packet boundaries", ":215-229", "TC-07", "Documented", "—", "Closed"),
 ("FW-001", "Info", "Initial stack pointer 0x2000 is one word past the RAM (latent)", "tb/fw/mailbox_fw.s", "—", "Documented", "—", "Closed"),
]
ws = wb.create_sheet("Findings")
ff, fl = table(ws, 1, ["ID", "Severity", "Description", "Location", "Found by", "Evidence",
                       "Fix", "Status", "Upstream issue / PR", "Comments"],
               [list(f) + ["", ""] for f in FIND], [14, 10, 56, 22, 22, 13, 44, 10, 22, 30],
               edit_cols=(8, 9, 10), center_cols=(2, 6, 8))
dvs = DataValidation(type="list", formula1='"Open,Fixed,Closed,Won\'t fix"')
ws.add_data_validation(dvs)
dvs.add(f"H{ff}:H{fl}")
status_format(ws, f"H{ff}:H{fl}")

# ---------------------------------------------------------------- Results
ws = wb.create_sheet("Regression")
ws["A1"] = "Regression results — Vivado 2026.1 xsim, seeds 1–5, 2026-10-20"
ws["A1"].font = TITLE
RES = [("TC-01", "openpcie_smoke_test", 5, 5, 5), ("TC-02", "openpcie_tx_directed_test", 5, 5, 5),
       ("TC-03", "openpcie_tx_random_test", 5, 5, 5), ("TC-04", "openpcie_tx_backpressure_test", 5, 0, 5),
       ("TC-05", "openpcie_tx_slow_sink_test", 5, 0, 5), ("TC-06", "openpcie_tx_burst_sink_test", 5, 0, 5),
       ("TC-07", "openpcie_rx_cpl_test", 5, 5, 5), ("TC-08", "openpcie_reg_access_test", 5, 5, 5),
       ("TC-09", "openpcie_sideband_test", 5, 5, 5), ("TC-10", "openpcie_reset_test", 5, 5, 5),
       ("TC-11", "openpcie_random_test", 5, 0, 5)]
rrows = []
for i, (tc, name, seeds, p0, p1) in enumerate(RES):
    r = 4 + i
    rrows.append([tc, name, seeds, p0, f"=C{r}-D{r}", p1, f"=C{r}-F{r}",
                  f'=IF(F{r}=C{r},IF(D{r}=C{r},"Pass","Pass with fixes"),"Fail")'])
f1, l1 = table(ws, 3, ["TC ID", "Test", "Seeds", "Pass: RTL as written", "Fail: RTL as written",
                        "Pass: with fixes", "Fail: with fixes", "Verdict"],
               rrows, [8, 32, 8, 14, 14, 14, 14, 16], edit_cols=(3, 4, 6), center_cols=(1, 3, 4, 5, 6, 7, 8))
t = l1 + 1
ws.cell(row=t, column=2, value="Total").font = BOLD
for c in "CDEFG":
    cell = ws[f"{c}{t}"]
    cell.value = f"=SUM({c}{f1}:{c}{l1})"
    cell.font, cell.border, cell.alignment = BOLD, BOX, CENTER
ws.cell(row=t + 1, column=2, value="Pass rate").font = BOLD
for c in "DF":
    cell = ws[f"{c}{t + 1}"]
    cell.value = f"=IF($C${t}=0,0,{c}{t}/$C${t})"
    cell.number_format = "0.0%"
    cell.font, cell.border, cell.alignment = BOLD, BOX, CENTER
ws.conditional_formatting.add(f"H{f1}:H{l1}", CellIsRule(operator="equal", formula=['"Pass"'], fill=GREEN))
ws.conditional_formatting.add(f"H{f1}:H{l1}", CellIsRule(operator="equal", formula=['"Pass with fixes"'], fill=AMBER))
ws.conditional_formatting.add(f"H{f1}:H{l1}", CellIsRule(operator="equal", formula=['"Fail"'], fill=RED))
ws.cell(row=t + 3, column=1,
        value="Every failure on the RTL as written is AXIS/PROTO + SCBD/TX from TX-PROTO-004 "
              "(4163 errors in the 20 failing runs: 3447 AXIS/PROTO, 400 SVA/AXIS, 196 SVA/SOC, 120 SCBD/TX). "
              "Source: build/xsim/regress_nofix and regress_fixed logs.").font = Font(name=F, size=9, italic=True)

# ---------------------------------------------------------------- Summary (first sheet)
ws = wb.create_sheet("Summary", 0)
ws["A1"] = "openPCIE Root Complex — Tier 1 Verification Tracker"
ws["A1"].font = TITLE
info = [("Document", "TP-OPENPCIE-T1 (tracking workbook)"), ("Version", "1.0"),
        ("Date", "2026-10-20"), ("DUT", "riscv_pcie_soc (openPCIE 6e48e11, rtl/openPCIE)"),
        ("Plans", "docs/verification_plan.md, docs/testplan.md"),
        ("Simulator", "Vivado 2026.1 xsim")]
for i, (k, v) in enumerate(info, 3):
    ws.cell(row=i, column=1, value=k).font = BOLD
    ws.cell(row=i, column=2, value=v).font = BODY

R, TC, TR, CV, RG, FD = "Features", "'Test Cases'", "Traceability", "Coverage", "Regression", "Findings"
rq = f"{R}!$H${first_req}:$H${last_req}"
metrics = [
 ("Requirements", f"=COUNTA({R}!$A${first_req}:$A${last_req})"),
 ("  P1 requirements", f'=COUNTIF({R}!$C${first_req}:$C${last_req},"P1")'),
 ("  Verified", f'=COUNTIF({rq},"Verified")'),
 ("  Fail (expected, traced to a finding)", f'=COUNTIF({rq},"Fail (expected)")'),
 ("  Partial / Open / Not run", f'=COUNTIF({rq},"Partial")+COUNTIF({rq},"Open")+COUNTIF({rq},"Not run")'),
 ("  Requirements covered by a test", f'=COUNTIF({TR}!$P${first_tr}:$P${last_tr},"Yes")'),
 ("Test cases", f"=COUNTA({TC}!$A${first_tc}:$A${last_tc})"),
 ("  Passing with fixes", f'=COUNTIF({TC}!$L${first_tc}:$L${last_tc},"Pass")'),
 ("  Passing on RTL as written", f'=COUNTIF({TC}!$K${first_tc}:$K${last_tc},"Pass")'),
 ("Regression runs", f"={RG}!C{t}"),
 ("  Pass rate, RTL as written", f"={RG}!D{t + 1}"),
 ("  Pass rate, with fixes", f"={RG}!F{t + 1}"),
 ("Functional coverage (weighted)", f"={CV}!F{tot}"),
 ("Assertion cover points hit (not collected on xsim)", f'=COUNTIF({CV}!$D${r0 + 1}:$D${r0 + len(COVP)},"Met")&" / {len(COVP)}"'),
 ("Open findings", f'=COUNTIF({FD}!$H${ff}:$H${fl},"Open")'),
]
ws.cell(row=10, column=1, value="Metric").font = HDR_FONT
ws.cell(row=10, column=2, value="Value").font = HDR_FONT
for c in (1, 2):
    ws.cell(row=10, column=c).fill = HDR_FILL
    ws.cell(row=10, column=c).border = BOX
for i, (k, f) in enumerate(metrics, 11):
    a = ws.cell(row=i, column=1, value=k)
    b = ws.cell(row=i, column=2, value=f)
    a.font = BOLD if not k.startswith("  ") else BODY
    b.font, a.border, b.border = BODY, BOX, BOX
    b.alignment = Alignment(horizontal="left")
    if "rate" in k or "coverage" in k:
        b.number_format = "0.0%"

lg = 11 + len(metrics) + 1
ws.cell(row=lg, column=1, value="How to use this workbook").font = BOLD
notes = [
 "Cells with a light-yellow fill are inputs: statuses, results, coverage hits, owners and comments. Everything else is reference data or a formula.",
 "Status columns use drop-down lists; the Summary sheet recalculates from them.",
 "Example: after a nightly run, enter the pass counts in Regression!D and F and the assertion cover hits in Coverage!C; the Summary updates.",
 "Requirement IDs match docs/verification_plan.md §6, and test IDs match docs/testplan.md §4.",
]
for i, n in enumerate(notes, lg + 1):
    c = ws.cell(row=i, column=1, value=n)
    c.font = BODY
    ws.merge_cells(start_row=i, start_column=1, end_row=i, end_column=4)
    c.alignment = Alignment(wrap_text=True, vertical="top")
    ws.row_dimensions[i].height = 28
ex = ws.cell(row=lg + 1, column=6, value="Input cell")
ex.fill, ex.font, ex.border = EDIT_FILL, BODY, BOX
ws.column_dimensions["A"].width = 40
ws.column_dimensions["B"].width = 48
ws.column_dimensions["C"].width = 14
ws.column_dimensions["D"].width = 14

for s in wb.worksheets:
    s.sheet_view.zoomScale = 90
# Formulas have no cached values until Excel recalculates; force it on open.
wb.calculation = CalcProperties(fullCalcOnLoad=True)
wb.save(OUT)
print("wrote", OUT)
