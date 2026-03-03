import cocotb
from cocotb.triggers import RisingEdge

from ucode_common import (
    CMD_EVENT,
    CSR_CTRL,
    Event,
    GoldenNeuron,
    OP_RECV,
    assert_model_matches,
    csr_write,
    encode_emit,
    encode_ui,
    encode_uio,
    force_runtime,
    program_words,
    read_unsigned,
    send_event,
    start_and_reset,
    wait_output_valid,
    wait_ready,
)


@cocotb.test()
async def test_output_hold_defers_next_event_accept(dut):
    model = await start_and_reset(dut)
    words = [(OP_RECV & 0x1F) << 11, encode_emit(tag=0)]
    await program_words(dut, model, words, base=0, vector_tag=0)

    await send_event(dut, model, Event(1, 0, 1))
    await wait_output_valid(dut)
    assert read_unsigned(dut.u_neuron.u_state.have_out_r) == 1, "first output never latched"

    dut.ui_in.value = encode_ui(CMD_EVENT, 2, 0)
    dut.uio_in.value = encode_uio(2, in_req=1, out_ack=0)

    saw_ready_low = False
    for _ in range(8):
        await RisingEdge(dut.clk)
        if (read_unsigned(dut.uio_out) & 0x1) == 0:
            saw_ready_low = True
            break
    assert saw_ready_low, "held output did not drive event ready low"
    assert read_unsigned(dut.u_neuron.u_state.last_sid_r) == 1, "blocked event updated state before output was cleared"

    dut.uio_in.value = encode_uio(2, in_req=1, out_ack=1)
    await RisingEdge(dut.clk)
    dut.uio_in.value = encode_uio(2, in_req=1, out_ack=0)
    model.ack_output()

    accepted = False
    for _ in range(40):
        await RisingEdge(dut.clk)
        if read_unsigned(dut.u_neuron.u_state.last_sid_r) == 2:
            accepted = True
            break
    assert accepted, "held request was not accepted after output ack"
    model.push_event(Event(2, 0, 2))

    await wait_output_valid(dut)
    assert (read_unsigned(dut.uo_out) & 0xFF) == model.out_data, "deferred accept emitted the wrong payload"

    dut.uio_in.value = encode_uio(0, in_req=1, out_ack=1)
    await RisingEdge(dut.clk)
    dut.uio_in.value = encode_uio(0, in_req=1, out_ack=0)
    model.ack_output()

    dut.uio_in.value = 0
    dut.ui_in.value = 0
    await wait_ready(dut)


@cocotb.test()
async def test_forced_fifo_clear_command(dut):
    model = await start_and_reset(dut)
    model.have_out = 1
    model.out_data = 0x80
    model.fifo.append(Event(1, 0, 5))
    model.fifo.append(Event(2, 1, 6))
    force_runtime(dut, model)
    await RisingEdge(dut.clk)
    assert read_unsigned(dut.u_neuron.u_event_fifo.slot0_valid) == 1, "forced queue slot0 missing"
    assert read_unsigned(dut.u_neuron.u_event_fifo.slot1_valid) == 1, "forced queue slot1 missing"

    await csr_write(dut, model, CSR_CTRL, 0x4)
    assert_model_matches(dut, model, "fifo_clear")

    await csr_write(dut, model, CSR_CTRL, 0x2)
    assert_model_matches(dut, model, "clear_out")
    assert read_unsigned(dut.u_neuron.u_state.have_out_r) == 0, "clear_out did not drop held output"
    await RisingEdge(dut.clk)
