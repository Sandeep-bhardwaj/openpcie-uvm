#
# openPCIE UVM - PicoRV32 mailbox firmware
# =========================================
#
# `riscv_pcie_soc` embeds a PicoRV32 whose program comes from an unconditional
# $readmemh("firmware.hex", ram).  The UVM environment therefore cannot reach
# the PCIe bridge registers directly - every access must be performed by the
# CPU.  This firmware turns the CPU into a UVM-controlled execution engine: it
# spins on a mailbox in RAM which the testbench drives by backdoor
# (openpcie_ram_bkdr_if, bound onto tb_top.dut.ram[]).
#
# Mailbox (byte addresses in the SoC's 8 KiB RAM):
#
#   0x1F00  CMD    TB writes non-zero to request work; FW clears it on completion
#   0x1F04  ARG0
#   0x1F08  ARG1
#   0x1F0C  ARG2
#   0x1F10  ARG3
#   0x1F14  RSP    FW result value (valid once ACK has advanced)
#   0x1F18  ACK    monotonic completion counter - the TB's synchronisation point
#   0x1F1C  ALIVE  0x1E5D0001 written once at boot; proves reset + fetch worked
#
# Commands:
#   1  SEND_TLP   ARG0->TX_HDR0, ARG1->TX_HDR1, ARG2->TX_HDR2, ARG3->TX_DATA
#                 (the TX_DATA write is what triggers transmission)
#   2  READ_REG   RSP = [BRIDGE_BASE + ARG0]
#   3  WRITE_REG  [BRIDGE_BASE + ARG0] = ARG1
#   4  NOP        no side effect; used as an ACK-ordering barrier
#
# Register usage (callee-agnostic; no stack, no calls):
#   t0  bridge base 0x30000000      t1  mailbox base 0x1F00
#   t3  ACK counter                 a0..a5  scratch
#
# Handshake contract the TB relies on:
#   CMD is cleared BEFORE ACK is incremented, so an observer that waits on ACK
#   is guaranteed to see a released mailbox.  RSP is written before ACK for the
#   same reason.

        .text
        .globl _start

_start:
        li      t0, 0x30000000          # bridge base
        li      t1, 0x00001F00          # mailbox base
        li      t3, 0                   # ACK counter

        # Clear the mailbox BEFORE publishing ALIVE.  Order matters: the
        # testbench treats ALIVE as "the firmware is initialised and about to
        # poll", and posts its first command the moment it sees the magic.  If
        # ALIVE were written first, the CMD clear below would land afterwards
        # and silently wipe that command - the mailbox would then sit idle for
        # ever with CMD=0 and ACK=0.  ALIVE is the release, so it goes last.
        sw      zero, 0(t1)             # MBOX.CMD   = 0 (idle)
        sw      zero, 20(t1)            # MBOX.RSP   = 0
        sw      t3, 24(t1)              # MBOX.ACK   = 0

        li      a0, 0x1E5D0001          # boot magic
        sw      a0, 28(t1)              # MBOX.ALIVE = magic - publishes readiness

poll:
        lw      a0, 0(t1)               # a0 = CMD
        beqz    a0, poll                # spin until the TB posts one

        li      a1, 1
        beq     a0, a1, do_send
        li      a1, 2
        beq     a0, a1, do_read
        li      a1, 3
        beq     a0, a1, do_write
        j       done                    # 4 (NOP) and anything unknown

do_send:
        lw      a2, 4(t1)               # ARG0 -> TLP DW0
        lw      a3, 8(t1)               # ARG1 -> TLP DW1
        lw      a4, 12(t1)              # ARG2 -> TLP DW2
        lw      a5, 16(t1)              # ARG3 -> payload DW
        sw      a2, 0(t0)               # TX_HDR0
        sw      a3, 4(t0)               # TX_HDR1
        sw      a4, 8(t0)               # TX_HDR2
        sw      a5, 12(t0)              # TX_DATA - fires the transmit FSM
        j       done

do_read:
        lw      a2, 4(t1)               # ARG0 = byte offset into the bridge
        add     a3, t0, a2
        lw      a4, 0(a3)
        sw      a4, 20(t1)              # MBOX.RSP
        j       done

do_write:
        lw      a2, 4(t1)               # ARG0 = byte offset
        lw      a3, 8(t1)               # ARG1 = value
        add     a4, t0, a2
        sw      a3, 0(a4)
        j       done

done:
        sw      zero, 0(t1)             # release the mailbox first ...
        addi    t3, t3, 1
        sw      t3, 24(t1)              # ... then publish completion
        j       poll
