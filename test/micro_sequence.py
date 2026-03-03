import cocotb

from ucode_common import (
    Event,
    GoldenNeuron,
    assert_commit_matches,
    assert_model_matches,
    ack_output,
    encode_integ,
    encode_leak,
    encode_recv,
    encode_reset,
    encode_spike_if_ge,
    encode_stdp,
    encode_tdec0,
    encode_tinc0,
    program_words,
    send_event_capture_preview,
    snapshot_commit_preview,
    soft_reset_runtime,
    start_and_reset,
    wait_event_commit,
    wait_ready,
    weight_write,
    write_init_rf,
)


async def _run_single_op_trace(dut, model: GoldenNeuron, event: Event, context: str) -> None:
    await write_init_rf(dut, model, model.rf)
    await soft_reset_runtime(dut, model)
    expected = model.clone()
    expected.fifo.append(event)
    commit = expected.service_once()

    await send_event_capture_preview(dut, event)
    preview = snapshot_commit_preview(dut)
    dut._log.info(
        "%s pre_rf=%s post_rf=%s spike=%d weight_wr=%d/%d->%d emit=%d",
        context,
        commit.pre_rf,
        commit.post_rf,
        commit.post_spike_flag,
        commit.weight_wr_en,
        commit.weight_wr_idx,
        commit.weight_wr_value,
        commit.emitted,
    )
    if (expected.ucode_len + 1) <= 1:
        assert_commit_matches(preview, commit, context)
    await wait_event_commit(dut)
    assert_model_matches(dut, expected, context)
    if expected.have_out:
        await ack_output(dut, expected)
        assert_model_matches(dut, expected, f"{context} ack")
    await wait_ready(dut)


@cocotb.test()
async def test_micro_leak_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(dut, model, [encode_leak(1)], base=0, vector_tag=0)
    model.rf[0] = 7
    await _run_single_op_trace(dut, model, Event(0, 0, 1), "micro_leak")


@cocotb.test()
async def test_micro_integ_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(dut, model, [encode_integ()], base=0, vector_tag=0)
    model.rf[0] = 3
    model.rf[1] = 2
    await _run_single_op_trace(dut, model, Event(0, 0, 2), "micro_integ")


@cocotb.test()
async def test_micro_spike_and_reset_single_step(dut):
    spike_model = await start_and_reset(dut)
    await program_words(dut, spike_model, [encode_spike_if_ge()], base=0, vector_tag=0)
    spike_model.rf[0] = 5
    spike_model.rf[2] = 4
    await _run_single_op_trace(dut, spike_model, Event(1, 0, 3), "micro_spike_if_ge")

    reset_model = spike_model.clone()
    await program_words(dut, reset_model, [encode_reset(mode=1)], base=0, vector_tag=0)
    reset_model.rf[0] = 6
    reset_model.rf[2] = 3
    await _run_single_op_trace(dut, reset_model, Event(1, 0, 4), "micro_reset")


@cocotb.test()
async def test_micro_trace_single_step(dut):
    dec_model = await start_and_reset(dut)
    await program_words(dut, dec_model, [encode_tdec0(1)], base=0, vector_tag=0)
    dec_model.rf[4] = 6
    await _run_single_op_trace(dut, dec_model, Event(2, 0, 5), "micro_tdec0")

    inc_model = dec_model.clone()
    await program_words(dut, inc_model, [encode_tinc0(3)], base=0, vector_tag=0)
    inc_model.rf[4] = 2
    await _run_single_op_trace(dut, inc_model, Event(2, 0, 6), "micro_tinc0")


@cocotb.test()
async def test_micro_stdp_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(
        dut,
        model,
        [
            encode_recv(),
            encode_spike_if_ge(),
            encode_stdp(1),
        ],
        base=0,
        vector_tag=0,
    )
    await weight_write(dut, model, 5, 0)
    model.rf[0] = 2
    model.rf[2] = 1
    model.rf[4] = 3
    model.rf[5] = 1
    await _run_single_op_trace(dut, model, Event(5, 0, 7), "micro_stdp_ltp")
