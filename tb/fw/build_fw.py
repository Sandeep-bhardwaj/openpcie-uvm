#!/usr/bin/env python3
"""
Build and self-test the PicoRV32 mailbox firmware for the openPCIE UVM TB.

    python tb/fw/build_fw.py            # assemble, self-test, write build/fw/firmware.hex
    python tb/fw/build_fw.py --no-test  # assemble and write only
    python tb/fw/build_fw.py --listing  # also write build/fw/mailbox_fw.lst

The self-test runs the assembled image on the bundled RV32I ISS against a
Python model of `riscv_pcie_soc`'s bridge (same address decode and same
register map as the RTL).  A failure here means the firmware is broken, and it
is caught on the workstation instead of inside a UVM regression.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rv32 import RV32Sim, assemble, to_hex          # noqa: E402

HERE = Path(__file__).resolve().parent
SRC = HERE / "mailbox_fw.s"
OUT = HERE.parent.parent / "build" / "fw"            # generated, not committed
HEX = OUT / "firmware.hex"
LST = OUT / "mailbox_fw.lst"

RAM_WORDS = 2048                # riscv_pcie_soc: logic [31:0] ram [0:2047]
BRIDGE_BASE = 0x3000_0000

# Mailbox byte offsets - MUST match mailbox_fw.s and openpcie_fw_mailbox.svh
MBOX_BASE = 0x1F00
MBOX = {"CMD": 0x00, "ARG0": 0x04, "ARG1": 0x08, "ARG2": 0x0C, "ARG3": 0x10,
        "RSP": 0x14, "ACK": 0x18, "ALIVE": 0x1C}
ALIVE_MAGIC = 0x1E5D_0001

CMD_SEND_TLP, CMD_READ_REG, CMD_WRITE_REG, CMD_NOP = 1, 2, 3, 4


class BridgeModel:
    """Reference model of the bridge slice of `riscv_pcie_soc`.

    Mirrors the RTL decode at riscv_pcie_soc.sv:176-254.  Writes to TX_DATA
    (offset 0x0C) latch a complete TLP and push it to `sent`, exactly as the
    RTL's write to `tx_data` moves the FSM into SEND_CYCLE_1.
    """

    def __init__(self):
        self.hdr = [0, 0, 0]
        self.sent: list[tuple[int, int, int, int]] = []
        self.rx_status = 0
        self.rx_data = 0
        self.rx_hdr_info = 0
        self.cfg_status = 0
        self.err_fatal = 0
        self.tx_buf_av = 0x20
        self.tx_state = 0

    def read(self, addr: int) -> int:
        if (addr >> 24) & 0xFF != 0x30:
            return 0xDEADBEEF
        if (addr >> 5) & 1:                          # mem_addr[5] -> PHY_STATUS
            return ((self.tx_state & 3) << 6) | (self.tx_buf_av & 0x3F)
        sel = (addr >> 2) & 7
        return {4: self.rx_status, 5: self.rx_data, 6: self.rx_hdr_info,
                7: ((self.err_fatal & 1) << 16) | (self.cfg_status & 0xFFFF)
                }.get(sel, 0)

    def write(self, addr: int, val: int, strb: int = 0xF) -> None:
        if (addr >> 24) & 0xFF != 0x30:
            return
        sel = (addr >> 2) & 7
        if sel < 3:
            self.hdr[sel] = val
        elif sel == 3:
            self.sent.append((self.hdr[0], self.hdr[1], self.hdr[2], val))


class Harness:
    """Drives the ISS the same way the UVM backdoor mailbox will."""

    def __init__(self, words: list[int]):
        self.bridge = BridgeModel()
        self.sim = RV32Sim(ram_words=RAM_WORDS,
                           mmio_read=self.bridge.read,
                           mmio_write=self.bridge.write)
        self.sim.load(words)

    def _w(self, off: int) -> int:
        return (MBOX_BASE + off) >> 2

    def peek(self, name: str) -> int:
        return self.sim.ram[self._w(MBOX[name])]

    def poke(self, name: str, val: int) -> None:
        self.sim.ram[self._w(MBOX[name])] = val & 0xFFFFFFFF

    def run(self, n: int) -> None:
        for _ in range(n):
            self.sim.step()
            if self.sim.trap:
                raise RuntimeError(self.sim.trap)

    def boot(self, budget: int = 200) -> None:
        self.run(budget)
        got = self.peek("ALIVE")
        if got != ALIVE_MAGIC:
            raise AssertionError(
                f"boot failed: ALIVE=0x{got:08x}, expected 0x{ALIVE_MAGIC:08x}")

    def step_until_alive(self, budget: int = 400) -> int:
        """Run one instruction at a time and stop the moment ALIVE appears.

        This is what the testbench actually does - it polls for the magic and
        posts a command as soon as it sees it.  Anything the firmware still
        writes to the mailbox after publishing ALIVE would clobber that
        command, so the boot sequence must publish ALIVE last.
        """
        for n in range(budget):
            if self.peek("ALIVE") == ALIVE_MAGIC:
                return n
            self.sim.step()
            if self.sim.trap:
                raise RuntimeError(self.sim.trap)
        raise AssertionError(f"ALIVE never appeared within {budget} instructions")

    def command(self, cmd: int, a0=0, a1=0, a2=0, a3=0, budget: int = 4000) -> int:
        """Post a command, wait for ACK to advance, return RSP."""
        ack0 = self.peek("ACK")
        for k, v in (("ARG0", a0), ("ARG1", a1), ("ARG2", a2), ("ARG3", a3)):
            self.poke(k, v)
        self.poke("CMD", cmd)
        for _ in range(budget):
            self.sim.step()
            if self.sim.trap:
                raise RuntimeError(self.sim.trap)
            if self.peek("ACK") != ack0:
                if self.peek("CMD") != 0:
                    raise AssertionError(
                        "handshake violation: ACK advanced while CMD still set")
                return self.peek("RSP")
        raise AssertionError(f"command {cmd} did not ACK within {budget} insns")


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------

def self_test(words: list[int]) -> int:
    checks, failures = 0, []

    def expect(cond, msg):
        nonlocal checks
        checks += 1
        if not cond:
            failures.append(msg)

    h = Harness(words)

    # -- boot ------------------------------------------------------------
    try:
        h.boot()
    except AssertionError as exc:
        print(f"FAIL  {exc}")
        return 1
    expect(h.peek("CMD") == 0, "CMD not idle after boot")
    expect(h.peek("ACK") == 0, "ACK not zero after boot")
    print("  ok  boot: ALIVE magic written, mailbox idle")

    # -- ALIVE must be the LAST thing boot writes -------------------------
    # Regression for a real failure: the boot sequence used to write ALIVE
    # first and clear CMD immediately afterwards.  The testbench posts its
    # first command the instant it sees ALIVE, so that clear wiped the
    # command and the mailbox sat idle for ever (CMD=0, ACK=0) while the CPU
    # ran perfectly.  Reproduce the exact race: stop at the first instruction
    # where ALIVE is set, post a command, and require it to survive.
    h2 = Harness(words)
    n = h2.step_until_alive()
    h2.poke("ARG0", 0x4000_0001)
    h2.poke("ARG1", 0x0000_000F)
    h2.poke("ARG2", 0x1111_0000)
    h2.poke("ARG3", 0xFEED_FACE)
    h2.poke("CMD", CMD_SEND_TLP)
    # Note CMD==0 with ACK==0 is a legitimate two-instruction transient: the
    # firmware clears CMD before bumping ACK on purpose, so that an observer
    # waiting on ACK always finds a released mailbox.  The signature of a
    # clobbered command is therefore ACK never moving *and* the bridge seeing
    # no traffic - not CMD going to zero.
    for _ in range(4000):
        h2.sim.step()
        if h2.sim.trap:
            raise RuntimeError(h2.sim.trap)
        if h2.peek("ACK") != 0:
            break
    expect(h2.peek("ACK") == 1,
           f"a command posted the instant ALIVE appeared never completed "
           f"(ACK={h2.peek('ACK')}, CMD=0x{h2.peek('CMD'):08x}). The boot "
           f"sequence is still writing the mailbox after publishing ALIVE, "
           f"so the command was wiped before the poll loop saw it.")
    expect(len(h2.bridge.sent) == 1 and
           h2.bridge.sent[0] == (0x4000_0001, 0x0000_000F, 0x1111_0000,
                                 0xFEED_FACE),
           f"command posted at ALIVE did not reach the bridge intact "
           f"({len(h2.bridge.sent)} transmit(s) seen)")
    if not failures:
        print(f"  ok  boot ordering: ALIVE published last (instruction {n}); "
              f"a command posted the instant it appears survives")

    # -- SEND_TLP: a 3DW MemWr32 with one payload DW ----------------------
    hdr0, hdr1, hdr2, data = 0x4000_0001, 0x0000_000F, 0x1234_5670, 0xCAFEBABE
    h.command(CMD_SEND_TLP, hdr0, hdr1, hdr2, data)
    expect(len(h.bridge.sent) == 1, "SEND_TLP produced no bridge transmit")
    if h.bridge.sent:
        expect(h.bridge.sent[0] == (hdr0, hdr1, hdr2, data),
               f"SEND_TLP payload mismatch: {[hex(x) for x in h.bridge.sent[0]]}")
    expect(h.peek("ACK") == 1, f"ACK should be 1, is {h.peek('ACK')}")
    print("  ok  SEND_TLP: all four bridge writes in order, TX_DATA last")

    # -- ordering: TX_DATA must be the trigger, written after the headers -
    h.bridge.sent.clear()
    h.command(CMD_WRITE_REG, 0x00, 0xAAAA_0000)
    h.command(CMD_WRITE_REG, 0x04, 0xBBBB_1111)
    h.command(CMD_WRITE_REG, 0x08, 0xCCCC_2222)
    expect(not h.bridge.sent, "header writes alone must not trigger a transmit")
    h.command(CMD_WRITE_REG, 0x0C, 0xDDDD_3333)
    expect(len(h.bridge.sent) == 1, "TX_DATA write did not trigger transmit")
    if h.bridge.sent:
        expect(h.bridge.sent[0] == (0xAAAA_0000, 0xBBBB_1111, 0xCCCC_2222,
                                    0xDDDD_3333), "WRITE_REG path corrupted")
    print("  ok  WRITE_REG: header regs are sticky, TX_DATA is the trigger")

    # -- READ_REG against every readable offset ---------------------------
    h.bridge.rx_status, h.bridge.rx_data = 0x5, 0xFEED_F00D
    h.bridge.rx_hdr_info, h.bridge.cfg_status = 0x0BAD_C0DE, 0x0117
    h.bridge.err_fatal, h.bridge.tx_buf_av = 1, 0x2A
    for off, want, name in [
        (0x10, 0x5, "RX_STATUS"),
        (0x14, 0xFEED_F00D, "RX_DATA"),
        (0x18, 0x0BAD_C0DE, "RX_HDR_INFO"),
        (0x1C, 0x0001_0117, "ERR_STATUS"),
        (0x20, 0x0000_002A, "PHY_STATUS"),
    ]:
        got = h.command(CMD_READ_REG, off)
        expect(got == want,
               f"READ_REG {name} (+0x{off:02x}) = 0x{got:08x}, want 0x{want:08x}")
    print("  ok  READ_REG: all five status registers decode correctly")

    # -- address aliasing -------------------------------------------------
    # The bridge decodes only mem_addr[5] and mem_addr[4:2], so the entire
    # 16 MiB at 0x30xxxxxx aliases with a 64-byte period.  The TB's RAL model
    # and any future firmware must stay inside 0x00..0x3F or it will silently
    # hit a mirror.  Pin the behaviour down so a decode change is caught.
    expect(h.command(CMD_READ_REG, 0x40) == 0,
           "offset 0x40 has addr[5]=0 and addr[4:2]=0 -> RTL default of 0")
    expect(h.command(CMD_READ_REG, 0x54) == h.command(CMD_READ_REG, 0x14),
           "offset 0x54 must alias RX_DATA at 0x14")
    expect(h.command(CMD_READ_REG, 0x60) == h.command(CMD_READ_REG, 0x20),
           "offset 0x60 must alias PHY_STATUS at 0x20")
    expect(h.command(CMD_READ_REG, 0x00) == 0,
           "write-only TX_HDR0 reads back as 0, not the written value")
    print("  ok  decode: 64-byte aliasing and write-only holes match the RTL")

    # -- NOP barrier and back-to-back throughput --------------------------
    ack0 = h.peek("ACK")
    for _ in range(20):
        h.command(CMD_NOP)
    expect(h.peek("ACK") == ack0 + 20,
           f"NOP barrier lost ACKs: {h.peek('ACK')} vs {ack0 + 20}")
    print("  ok  NOP: 20 back-to-back commands, no lost or duplicated ACKs")

    # -- sustained mixed traffic -----------------------------------------
    h.bridge.sent.clear()
    for i in range(64):
        h.command(CMD_SEND_TLP, 0x4000_0001, i, 0x2000 + i * 4, 0xA5A5_0000 | i)
    expect(len(h.bridge.sent) == 64,
           f"expected 64 transmits, got {len(h.bridge.sent)}")
    bad = [i for i, s in enumerate(h.bridge.sent)
           if s != (0x4000_0001, i, 0x2000 + i * 4, 0xA5A5_0000 | i)]
    expect(not bad, f"payload corruption on transmits {bad[:5]}")
    print("  ok  soak: 64 sequential TLPs, payloads intact")

    # -- the firmware must never fall out of its loop ---------------------
    expect(h.sim.trap is None, f"CPU trapped: {h.sim.trap}")
    expect(h.peek("CMD") == 0, "mailbox left busy at end of test")

    print()
    if failures:
        print(f"SELF-TEST FAILED: {len(failures)}/{checks} checks failed")
        for f in failures:
            print(f"  FAIL  {f}")
        return 1
    print(f"SELF-TEST PASSED: {checks} checks, {h.sim.retired} instructions retired")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--no-test", action="store_true")
    ap.add_argument("--listing", action="store_true")
    ap.add_argument("-o", "--out", type=Path, default=HEX)
    args = ap.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    words, labels = assemble(SRC.read_text(encoding="utf-8"), base=0)
    print(f"assembled {SRC.name}: {len(words)} instructions "
          f"({len(words) * 4} bytes, {100 * len(words) / RAM_WORDS:.1f}% of RAM)")

    if args.listing:
        rev = {v: k for k, v in labels.items()}
        lines = []
        for i, w in enumerate(words):
            tag = rev.get(i * 4, "")
            lines.append(f"{i*4:04x}: {w:08x}  {tag + ':' if tag else ''}")
        LST.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"listing -> {LST}")

    rc = 0 if args.no_test else self_test(words)
    if rc == 0:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(to_hex(words, RAM_WORDS), encoding="utf-8")
        print(f"image   -> {args.out}  ({RAM_WORDS} words)")
    else:
        print("image NOT written - fix the firmware first", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
