# test/test_neuron.py
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

TYPE_SPIKE = 0b000  # uo_out[6:4]
TYPE_ACT   = 0b101  # uo_out[6:4]

ADDR_RESET = 61
ADDR_ARM   = 62
ADDR_CFG   = 63

# cfg_op is uio_in[3:2], cfg_arg is uio_in[7:4]
CFG_SET_WIDX = 0b00
CFG_WRITE_W  = 0b01
CFG_SET_MODE = 0b10

MODE_LIF  = 0b00
MODE_TD   = 0b01
MODE_FST  = 0b10
MODE_CONV = 0b11

CLOCK_PERIOD_NS = int(os.getenv("CLOCK_PERIOD_NS", "20"))


def pack_event(is_tick: int, polarity: int, addr: int) -> int:
    assert 0 <= is_tick <= 1
    assert 0 <= polarity <= 1
    assert 0 <= addr <= 63
    return (is_tick << 7) | (polarity << 6) | (addr & 0x3F)


def set_uio_bits(uio_val: int, bit: int, v: int) -> int:
    if v:
        return uio_val | (1 << bit)
    return uio_val & ~(1 << bit)


def set_uio_slice(uio_val: int, msb: int, lsb: int, v: int) -> int:
    width = msb - lsb + 1
    mask = ((1 << width) - 1) << lsb
    uio_val &= ~mask
    uio_val |= (v << lsb) & mask
    return uio_val


async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0  # in_req=0, out_ack=0, cfg bits=0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    # send soft reset event too (optional but nice)
    await send_event(dut, pack_event(0, 0, ADDR_RESET))


async def send_event(dut, ui_byte: int, cfg_op: int = 0, cfg_arg: int = 0):
    """
    Drives one input handshake:
      - ui_in = ui_byte
      - uio_in[7:4]=cfg_arg, uio_in[3:2]=cfg_op
      - uio_in[0]=in_req
    Waits until in_ack (uio_out[0]) is high at a rising clk edge, then deasserts in_req.
    """
    # load payload
    dut.ui_in.value = ui_byte

    # set cfg sideband
    u = int(dut.uio_in.value)
    u = set_uio_slice(u, 7, 4, cfg_arg & 0xF)
    u = set_uio_slice(u, 3, 2, cfg_op & 0x3)

    # ensure out_ack low unless we're explicitly consuming output
    u = set_uio_bits(u, 1, 0)  # out_ack = 0

    # assert in_req
    u = set_uio_bits(u, 0, 1)
    dut.uio_in.value = u

    # wait for acceptance (in_req & in_ack sampled on clk)
    for _ in range(2000):
        await RisingEdge(dut.clk)
        in_ack = int(dut.uio_out.value) & 0x1
        if in_ack == 1:
            # accepted this cycle (since in_req=1)
            break
    else:
        raise RuntimeError("Timeout waiting for in_ack to accept event")

    # Deassert immediately after the accepting edge so this request is consumed once.
    # If we wait an extra cycle, level-sensitive valid/ready semantics can accept twice.
    u = int(dut.uio_in.value)
    u = set_uio_bits(u, 0, 0)
    dut.uio_in.value = u

    # keep ui_in stable for one more cycle for safety
    await RisingEdge(dut.clk)


async def read_output_event(dut, timeout_cycles: int = 2000):
    """
    Wait until out_req is asserted, then pulse out_ack for one cycle and return uo_out byte.
    """
    # wait for out_req
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        out_req = (int(dut.uio_out.value) >> 1) & 0x1
        if out_req:
            break
    else:
        raise RuntimeError("Timeout waiting for out_req")

    # sample output before ack (should be stable)
    data = int(dut.uo_out.value) & 0xFF

    # pulse out_ack for one cycle
    u = int(dut.uio_in.value)
    u = set_uio_bits(u, 1, 1)  # out_ack=1
    dut.uio_in.value = u
    await RisingEdge(dut.clk)

    u = int(dut.uio_in.value)
    u = set_uio_bits(u, 1, 0)  # out_ack=0
    dut.uio_in.value = u
    await RisingEdge(dut.clk)

    return data


def decode_out(byte_val: int):
    """
    out format: b7=1, b6:b4=type, b3:b0=payload
    """
    valid = (byte_val >> 7) & 1
    typ = (byte_val >> 4) & 0x7
    payload = byte_val & 0xF
    return valid, typ, payload


def get_wtab_entry_from_shadow(shadow_wtab: dict, idx: int) -> int:
    """Helper for expected weights in tests."""
    return shadow_wtab.get(idx, 0)


async def cfg_set_weight(dut, idx: int, w: int):
    """
    Writes wtab[idx] = w (2-bit), using:
      cfg_op=SET_WIDX, cfg_arg=idx
      cfg_op=WRITE_W,  cfg_arg=w (in low 2 bits)
    """
    assert 0 <= idx <= 15
    assert 0 <= w <= 3
    await send_event(dut, pack_event(0, 0, ADDR_CFG), cfg_op=CFG_SET_WIDX, cfg_arg=idx)
    await send_event(dut, pack_event(0, 0, ADDR_CFG), cfg_op=CFG_WRITE_W, cfg_arg=w)


async def cfg_set_mode(dut, mode: int, stream_act: int = 1, learn_en: int = 0):
    """
    cfg_op=SET_MODE, cfg_arg[1:0]=mode, cfg_arg[2]=stream_act, cfg_arg[3]=learn_en
    """
    assert 0 <= mode <= 3
    assert 0 <= stream_act <= 1
    assert 0 <= learn_en <= 1
    cfg_arg = (learn_en << 3) | (stream_act << 2) | (mode & 0x3)
    await send_event(dut, pack_event(0, 0, ADDR_CFG), cfg_op=CFG_SET_MODE, cfg_arg=cfg_arg)


@cocotb.test()
async def test_all(dut):
    """
    Multi-scenario test:
      1) LIF mode: program wtab[0]=3, spike addr0, tick -> expect ACT payload ~3
      2) TD mode: accumulate a few spikes, tick -> ACT payload matches diff
      3) FST mode: arm, tick N times -> ACT increments, spike -> SPIKE payload ~N
      4) CONV mode: spike + tick -> ACT shows conv sum progression
    """
    # Start a clock (TT templates expect this)
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())

    dut._log.info("Reset")
    await reset_dut(dut)

    # ---------- Scenario 1: LIF ----------
    dut._log.info("Scenario 1: LIF mode + weight programming + activation stream")

    await cfg_set_mode(dut, MODE_LIF, stream_act=1, learn_en=0)
    await cfg_set_weight(dut, idx=0, w=3)

    # Send one spike to addr 0 (uses programmable weight)
    await send_event(dut, pack_event(0, 0, 0))

    # Send a tick -> should emit activation (unless spike fired, which won't at weight=3 and thr=32)
    await send_event(dut, pack_event(1, 0, 0))
    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    assert typ == TYPE_ACT, f"Expected ACT, got typ={typ} out=0x{out:02x}"
    # Expect payload to reflect membrane low nibble ~ 3
    assert payload == 3, f"Expected activation 3, got {payload}"

    # ---------- Scenario 2: TD ----------
    dut._log.info("Scenario 2: TD mode (diff) + activation stream")

    await cfg_set_mode(dut, MODE_TD, stream_act=1, learn_en=0)

    # Accumulate: 2 spikes on addr0 => curr = 6
    await send_event(dut, pack_event(0, 0, 0))
    await send_event(dut, pack_event(0, 0, 0))

    # Tick: diff = curr - prev = 6
    await send_event(dut, pack_event(1, 0, 0))
    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    # If diff >= TD_THR (4), tile emits SPIKE with payload=diff[3:0]
    # so expect SPIKE payload 6 here.
    assert typ == TYPE_SPIKE, f"Expected SPIKE in TD (diff>=thr), got typ={typ} out=0x{out:02x}"
    assert payload == 6, f"Expected TD spike payload 6, got {payload}"

    # Next tick with no new spikes => diff should be 0, so should ACT (stream) with 0
    await send_event(dut, pack_event(1, 0, 0))
    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    assert typ == TYPE_ACT, f"Expected ACT when no TD spike, got typ={typ} out=0x{out:02x}"
    assert payload == 0

    # ---------- Scenario 3: FST ----------
    dut._log.info("Scenario 3: FST mode + arm + tick count + spike")

    await cfg_set_mode(dut, MODE_FST, stream_act=1, learn_en=0)

    # Arm first-spike timer
    await send_event(dut, pack_event(0, 0, ADDR_ARM))

    # Send 5 ticks, and consume 5 activation samples
    for i in range(1, 6):
        await send_event(dut, pack_event(1, 0, 0))
        out = await read_output_event(dut)
        valid, typ, payload = decode_out(out)
        assert valid == 1
        assert typ == TYPE_ACT, f"Expected ACT during armed FST, got typ={typ} out=0x{out:02x}"
        # payload should be fst_t low nibble; after i ticks it should be i (starting from 0)
        assert payload == (i & 0xF), f"Expected FST act {i}, got {payload}"

    # Send a spike; should output SPIKE with payload=fst_t (5)
    await send_event(dut, pack_event(0, 0, 0))  # any spike while armed
    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    assert typ == TYPE_SPIKE, f"Expected SPIKE on first spike in FST, got typ={typ} out=0x{out:02x}"
    assert payload == 5, f"Expected FST spike payload 5, got {payload}"

    # ---------- Scenario 4: CONV ----------
    dut._log.info("Scenario 4: CONV mode + spike activity + tick activation")

    await cfg_set_mode(dut, MODE_CONV, stream_act=1, learn_en=0)

    # With kernel K0=1,K1=2,K2=1,K3=0 and shift-in activity bit each tick:
    # We'll do: spike, tick -> shift gets 1, sum becomes 1, ACT expected 1 (no spike)
    await send_event(dut, pack_event(0, 0, 16))  # spike (non-prog addr is fine)
    await send_event(dut, pack_event(1, 0, 0))   # tick
    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    # sum=1 so expect ACT with payload 1
    assert typ == TYPE_ACT, f"Expected ACT for conv sum<thr, got typ={typ} out=0x{out:02x}"
    assert payload == 1, f"Expected conv act 1, got {payload}"

    # spike again, tick: shift becomes 11.., sum should increase (likely 1+2=3), which meets CONV_THR=3 -> SPIKE
    await send_event(dut, pack_event(0, 0, 16))
    await send_event(dut, pack_event(1, 0, 0))
    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    assert typ == TYPE_SPIKE, f"Expected SPIKE when conv sum>=thr, got typ={typ} out=0x{out:02x}"
    # payload is {1'b0,sum_next} => should be 3 if our reasoning matches
    assert payload == 3, f"Expected conv spike payload 3, got {payload}"

    # ---------- Scenario 5: STDP-lite learning (LIF) ----------
    dut._log.info("Scenario 5: STDP-lite learning in LIF mode (serial LTP scan)")

    # Reset weights we care about
    await send_event(dut, pack_event(0, 0, ADDR_RESET))

    # Enable learning + activation stream
    await cfg_set_mode(dut, MODE_LIF, stream_act=1, learn_en=1)

    # Program synapse 0 and 1 to weight 1 (known baseline)
    await cfg_set_weight(dut, idx=0, w=1)
    await cfg_set_weight(dut, idx=1, w=1)

    # Provide pre-spikes on synapse 0 and 1 to set pre_trace bits
    await send_event(dut, pack_event(0, 0, 0))
    await send_event(dut, pack_event(0, 0, 1))

    # Now drive neuron to a post-spike by sending enough spikes on synapse 0.
    # We already sent two pre-spikes above (addr 0 and 1), each adding 1 in LIF mode.
    # Starting from lif_V=2, we need 30 more spikes at weight=1 to reach threshold 32.
    for _ in range(30):
        await send_event(dut, pack_event(0, 0, 0))

    # Consume the spike output
    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    assert typ == TYPE_SPIKE, f"Expected LIF post-spike, got typ={typ} out=0x{out:02x}"

    # Learning scan increments one synapse per accepted input event.
    # Send 16 ticks to allow scan to complete.
    for _ in range(16):
        await send_event(dut, pack_event(1, 0, 0))
        # Each tick should produce ACT (stream), consume it to keep pipeline flowing.
        out = await read_output_event(dut)
        valid, typ, payload = decode_out(out)
        assert valid == 1
        assert typ in (TYPE_ACT, TYPE_SPIKE)

    # We don't have a readback opcode for weights in this design, so we validate learning indirectly:
    # After LTP, synapse 0 and 1 weights should have increased to 2.
    # We can observe faster firing: with weight 2, it should take 16 spikes to reach threshold 32.

    # Clear membrane with reset event (does not clear weights)
    await send_event(dut, pack_event(0, 0, ADDR_RESET))

    # Drive 16 spikes on synapse 0; should now fire (if weight became 2)
    for _ in range(16):
        await send_event(dut, pack_event(0, 0, 0))

    out = await read_output_event(dut)
    valid, typ, payload = decode_out(out)
    assert valid == 1
    assert typ == TYPE_SPIKE, f"Expected faster LIF spike after learning, got typ={typ} out=0x{out:02x}"

    dut._log.info("All scenarios passed.")
