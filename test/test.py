# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start neuron smoke test")

    # 100 kHz test clock.
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # Default mode is LIF with activation streaming enabled.
    # Send a tick event: ui_in[7]=1 (is_tick), payload otherwise zero.
    tick_event = 0x80
    dut.ui_in.value = tick_event
    dut.uio_in.value = 0x01  # in_req=1

    got_ack = False
    for _ in range(32):
        await ClockCycles(dut.clk, 1)
        if int(dut.uio_out.value) & 0x01:
            got_ack = True
            break
    assert got_ack, "Timed out waiting for in_ack"

    # Deassert input request after acceptance.
    dut.uio_in.value = 0x00
    await ClockCycles(dut.clk, 1)

    # Expect one output activation packet: valid=1, type=ACT(101), payload=0 -> 0xD0.
    got_out_req = False
    for _ in range(16):
        await ClockCycles(dut.clk, 1)
        if int(dut.uio_out.value) & 0x02:
            got_out_req = True
            break
    assert got_out_req, "Timed out waiting for out_req"
    assert int(dut.uo_out.value) == 0xD0, f"Unexpected output data: 0x{int(dut.uo_out.value):02X}"

    # Acknowledge and drain output.
    dut.uio_in.value = 0x02  # out_ack=1
    drained = False
    for _ in range(32):
        await ClockCycles(dut.clk, 1)
        if (int(dut.uio_out.value) & 0x02) == 0:
            drained = True
            break
    assert drained, "Timed out waiting for out_req to clear"
    dut.uio_in.value = 0x00
