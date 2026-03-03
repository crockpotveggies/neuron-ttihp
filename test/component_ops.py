import cocotb

from ucode_common import (
    Event,
    GoldenNeuron,
    OP_EMIT,
    OP_RECV,
    OP_REFRACT,
    TERN_NEG,
    TERN_POS,
    assert_commit_matches,
    assert_model_matches,
    ack_output,
    encode_accum_w,
    encode_emit,
    encode_ldi,
    encode_leak,
    encode_refract,
    encode_recv,
    encode_spike_if_ge,
    encode_stdp,
    encode_tdec0,
    encode_tdec1,
    encode_tinc0,
    encode_tinc1,
    program_words,
    read_unsigned,
    sat4,
    send_event_capture_preview,
    send_event,
    snapshot_commit_preview,
    soft_reset_runtime,
    start_and_reset,
    wait_event_commit,
    wait_ready,
    weight_write,
    write_init_rf,
)


async def _run_single_case(dut, initial: GoldenNeuron, event: Event, context: str) -> None:
    await write_init_rf(dut, initial, initial.rf)
    await soft_reset_runtime(dut, initial)
    expected = initial.clone()
    expected.fifo.append(event)
    commit = expected.service_once()

    await send_event_capture_preview(dut, event)
    preview = snapshot_commit_preview(dut)
    if (expected.ucode_len + 1) <= 1:
        assert_commit_matches(preview, commit, f"{context} preview")
    await wait_event_commit(dut)
    assert_model_matches(dut, expected, f"{context} commit")
    if expected.have_out:
        await ack_output(dut, expected)
        assert_model_matches(dut, expected, f"{context} ack")
    await wait_ready(dut)


@cocotb.test()
async def test_component_ldi_exhaustive(dut):
    base = await start_and_reset(dut)
    event = Event(0, 0, 0)
    for imm in range(-4, 4):
        await program_words(dut, base, [encode_ldi(rd=0, imm=imm)], base=0, vector_tag=0)
        await _run_single_case(dut, base.clone(), event, f"ldi imm={imm}")


@cocotb.test()
async def test_component_leak_exhaustive(dut):
    base = await start_and_reset(dut)
    event = Event(0, 0, 0)
    leak_cover = set()

    for value in range(-8, 8):
        for shift in range(4):
            await program_words(dut, base, [encode_leak(shift)], base=0, vector_tag=0)
            leak_case = base.clone()
            leak_case.rf[0] = value
            leak_cover.add(sat4(value - (value >> shift)))
            await _run_single_case(dut, leak_case, event, f"leak v={value} sh={shift}")

    assert min(leak_cover) < 0 and 0 in leak_cover and max(leak_cover) > 0, "leak sweep missed expected spread"


@cocotb.test()
async def test_component_spike_flag_boundary_exhaustive(dut):
    model = await start_and_reset(dut)
    await program_words(dut, model, [encode_spike_if_ge()], base=0, vector_tag=0)
    event = Event(0, 0, 0)

    for membrane in range(-8, 8):
        for threshold in range(-8, 8):
            case = model.clone()
            case.rf[0] = membrane
            case.rf[2] = threshold
            await _run_single_case(dut, case, event, f"spike_if_ge v={membrane} th={threshold}")


@cocotb.test()
async def test_component_trace_and_stdp_exhaustive(dut):
    base = await start_and_reset(dut)
    event = Event(3, 0, 0)

    for value in range(-8, 8):
        for shift in range(4):
            await program_words(dut, base, [encode_tdec0(shift)], base=0, vector_tag=0)
            tdec0 = base.clone()
            tdec0.rf[4] = value
            await _run_single_case(dut, tdec0, event, f"tdec0 v={value} sh={shift}")

            await program_words(dut, base, [encode_tdec1(shift)], base=0, vector_tag=0)
            tdec1 = base.clone()
            tdec1.rf[5] = value
            await _run_single_case(dut, tdec1, event, f"tdec1 v={value} sh={shift}")

        for inc in (-4, -1, 1, 3):
            await program_words(dut, base, [encode_tinc0(inc)], base=0, vector_tag=0)
            tinc0 = base.clone()
            tinc0.rf[4] = value
            await _run_single_case(dut, tinc0, event, f"tinc0 v={value} inc={inc}")

            await program_words(dut, base, [encode_tinc1(inc)], base=0, vector_tag=0)
            tinc1 = base.clone()
            tinc1.rf[5] = value
            await _run_single_case(dut, tinc1, event, f"tinc1 v={value} inc={inc}")

    covered_weights = set()
    modes = (1, 2, 3)
    for mode in modes:
        await program_words(
            dut,
            base,
            [
                encode_recv(),
                encode_spike_if_ge(),
                encode_stdp(mode),
            ],
            base=0,
            vector_tag=0,
        )
        for tpre in range(0, 4):
            for tpost in range(0, 4):
                for spike in (0, 1):
                    for weight_code, weight_value in ((TERN_NEG, -1), (0, 0), (TERN_POS, 1)):
                        await weight_write(dut, base, 3, weight_code)
                        case = base.clone()
                        case.rf[0] = 1 if spike else 0
                        case.rf[2] = 0 if spike else 1
                        case.rf[4] = tpre
                        case.rf[5] = tpost
                        case.weights[3] = weight_value
                        covered_weights.add(weight_value)
                        await _run_single_case(
                            dut,
                            case,
                            event,
                            f"stdp mode={mode} tpre={tpre} tpost={tpost} spike={spike} w={weight_code}",
                        )

    assert covered_weights == {-1, 0, 1}, "stdp sweep missed a ternary weight state"


@cocotb.test()
async def test_component_recv_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(dut, model, [encode_recv()], base=0, vector_tag=0)
    await _run_single_case(dut, model.clone(), Event(7, 1, 9), "recv")


@cocotb.test()
async def test_component_accum_w_ternary_sweep(dut):
    model = await start_and_reset(dut)
    await program_words(dut, model, [encode_recv(), encode_accum_w()], base=0, vector_tag=0)

    for weight_code, label in ((TERN_NEG, "neg"), (0, "zero"), (TERN_POS, "pos")):
        await weight_write(dut, model, 1, weight_code)
        for initial_i in range(-8, 8):
            case = model.clone()
            case.rf[1] = initial_i
            await _run_single_case(dut, case, Event(1, 0, 1), f"accum_w_{label}_i={initial_i}")


@cocotb.test()
async def test_component_refract_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(
        dut,
        model,
        [
            encode_spike_if_ge(),
            encode_refract(imm=1, shift=1),
        ],
        base=0,
        vector_tag=0,
    )

    spike_case = model.clone()
    spike_case.rf[0] = 4
    spike_case.rf[2] = 2
    spike_case.rf[3] = 0
    await _run_single_case(dut, spike_case, Event(0, 0, 2), "refract_spike_load")

    decay_case = model.clone()
    decay_case.rf[0] = 0
    decay_case.rf[2] = 3
    decay_case.rf[3] = 4
    await _run_single_case(dut, decay_case, Event(0, 0, 3), "refract_decay")


@cocotb.test()
async def test_component_recv_w_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(
        dut,
        model,
        [
            encode_recv(),
            encode_accum_w(),
        ],
        base=0,
        vector_tag=0,
    )
    await weight_write(dut, model, 4, TERN_POS)

    case = model.clone()
    await _run_single_case(dut, case, Event(4, 0, 7), "recv_w")


@cocotb.test()
async def test_component_emit_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(
        dut,
        model,
        [
            encode_recv(),
            encode_emit(tag=2),
        ],
        base=0,
        vector_tag=0,
    )
    await send_event(dut, model, Event(6, 0, 8))
    assert_model_matches(dut, model, "emit commit")
    assert model.have_out == 1, "EMIT should latch an output beat"
    assert model.out_data == (0x80 | (2 << 5) | (6 << 1)), "EMIT packed the wrong output payload"
    assert (read_unsigned(dut.uo_out) & 0xFF) == model.out_data, "EMIT did not drive the expected output byte"
    await ack_output(dut, model)
    await wait_ready(dut)


@cocotb.test()
async def test_component_stdp_clamp_single_step(dut):
    model = await start_and_reset(dut)
    await program_words(
        dut,
        model,
        [
            encode_recv(),
            encode_ldi(0, 1),
            encode_spike_if_ge(),
            encode_tinc0(1),
            encode_stdp(1),
        ],
        base=0,
        vector_tag=0,
    )
    await weight_write(dut, model, 2, TERN_POS)
    await send_event(dut, model, Event(2, 0, 9))
    assert_model_matches(dut, model, "stdp_clamp commit")
    assert model.weights[2] == 1, "STDP_LITE should preserve the positive ternary clamp"
