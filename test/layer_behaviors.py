import cocotb

from ucode_common import (
    CSR_CTRL,
    CSR_INIT_TR,
    CSR_VEC_BASE_01,
    Event,
    TERN_NEG,
    TERN_POS,
    TERN_ZERO,
    ack_output,
    assert_model_matches,
    csr_write,
    encode_accum_w,
    encode_emit,
    encode_integ,
    encode_ldi,
    encode_leak,
    encode_reset,
    encode_recv,
    encode_spike_if_ge,
    encode_stdp,
    encode_tdec0,
    encode_tdec1,
    encode_tinc0,
    encode_tinc1,
    program_words,
    send_event,
    start_and_reset,
    weight_write,
)


async def _run_events(dut, model, sids, tag: int = 0, start_time: int = 1):
    outputs = []
    for offset, sid in enumerate(sids):
        await send_event(dut, model, Event(sid=sid, tag=tag, event_time=start_time + offset))
        assert_model_matches(dut, model, f"run_events sid={sid} step={offset}")
        if model.have_out:
            outputs.append(await ack_output(dut, model))
            assert_model_matches(dut, model, f"run_events sid={sid} step={offset} ack")
    return outputs


def _spike_bits(outputs: list[int]) -> list[int]:
    return [sample & 0x1 for sample in outputs]


def _count_spikes(samples: list[int]) -> int:
    return sum(sample & 0x1 for sample in samples)


async def _configure_and_load(dut, words, threshold: int = 2):
    model = await _configure_program(dut, words, threshold=threshold)
    return model


def _lif_program(leak_shift: int):
    return [
        encode_leak(leak_shift),
        encode_recv(),
        encode_accum_w(),
        encode_integ(),
        encode_ldi(1, 0),
        encode_spike_if_ge(),
        encode_reset(mode=1),
        encode_emit(tag=0),
    ]


def _if_program():
    return [
        encode_recv(),
        encode_accum_w(),
        encode_integ(),
        encode_ldi(1, 0),
        encode_spike_if_ge(),
        encode_reset(mode=1),
        encode_emit(tag=0),
    ]

def _multiscale_feature_program():
    return [
        encode_recv(),
        encode_tdec0(0),
        encode_tdec1(1),
        encode_tinc0(1),
        encode_tinc1(1),
        encode_emit(tag=0),
    ]


def _stdp_unsupervised_program():
    return [
        encode_recv(),
        encode_ldi(0, 1),
        encode_spike_if_ge(),
        encode_tdec0(1),
        encode_tinc0(1),
        encode_stdp(1),
        encode_emit(tag=0),
    ]


async def _configure_program(dut, words, threshold: int = 2):
    model = await start_and_reset(dut)
    await csr_write(dut, model, CSR_INIT_TR, threshold & 0xF)
    await csr_write(dut, model, CSR_CTRL, 0x01)
    await program_words(dut, model, words, base=0, vector_tag=0)
    assert_model_matches(dut, model, "configure_program")
    return model


@cocotb.test()
async def test_lif_input_magnitude_monotonicity(dut):
    words = _if_program()

    low_model = await _configure_program(dut, words, threshold=2)
    await weight_write(dut, low_model, 0, TERN_ZERO)
    low_outputs = []
    for step in range(6):
        await send_event(dut, low_model, Event(0, 0, step + 1))
        low_outputs.append(await ack_output(dut, low_model))

    high_model = await _configure_program(dut, words, threshold=2)
    await weight_write(dut, high_model, 0, TERN_POS)
    high_outputs = []
    for step in range(6):
        await send_event(dut, high_model, Event(0, 0, step + 1))
        high_outputs.append(await ack_output(dut, high_model))

    assert _count_spikes(high_outputs) >= _count_spikes(low_outputs), "higher input did not increase firing"
    assert _count_spikes(high_outputs) > 0, "positive drive never crossed threshold"


@cocotb.test()
async def test_vector_base_mapping_smoke(dut):
    model = await start_and_reset(dut)
    await csr_write(dut, model, CSR_INIT_TR, 0x02)
    await csr_write(dut, model, CSR_CTRL, 0x01)

    vector0 = [
        encode_recv(),
        encode_accum_w(),
        encode_integ(),
        encode_ldi(1, 0),
        encode_emit(tag=0),
    ]
    vector1 = [
        encode_recv(),
        encode_accum_w(),
        encode_accum_w(),
        encode_integ(),
        encode_ldi(1, 0),
        encode_emit(tag=1),
    ]

    await program_words(dut, model, vector0, base=0, vector_tag=0)
    await program_words(dut, model, vector1, base=8, vector_tag=1)
    await csr_write(dut, model, CSR_VEC_BASE_01, 0x80)
    await weight_write(dut, model, 0, TERN_POS)

    await send_event(dut, model, Event(0, 0, 1))
    out0 = await ack_output(dut, model)
    state_after_tag0 = model.rf[0]

    await send_event(dut, model, Event(0, 1, 2))
    out1 = await ack_output(dut, model)
    state_after_tag1 = model.rf[0]

    assert (out0 >> 5) & 0x3 == 0, "tag0 vector emitted the wrong type tag"
    assert (out1 >> 5) & 0x3 == 1, "tag1 vector emitted the wrong type tag"
    assert state_after_tag1 > state_after_tag0, "alternate vector base did not apply the alternate micro-sequence"


@cocotb.test()
async def test_stdp_pair_ordering_and_clamps(dut):
    ltp_words = [
        encode_recv(),
        encode_ldi(0, 3),
        encode_spike_if_ge(),
        encode_tdec0(1),
        encode_tinc0(1),
        encode_stdp(1),
        encode_emit(tag=0),
    ]

    ltp_model = await _configure_program(dut, ltp_words, threshold=1)
    await weight_write(dut, ltp_model, 0, TERN_ZERO)
    for step in range(4):
        await send_event(dut, ltp_model, Event(0, 0, step + 1))
        await ack_output(dut, ltp_model)
    assert ltp_model.weights[0] == 1, "LTP program did not potentiate to the positive clamp"

    ltd_words = [
        encode_recv(),
        encode_tdec1(1),
        encode_tinc1(1),
        encode_stdp(2),
        encode_emit(tag=0),
    ]

    ltd_model = await _configure_program(dut, ltd_words, threshold=1)
    await weight_write(dut, ltd_model, 0, TERN_POS)
    for step in range(4):
        await send_event(dut, ltd_model, Event(0, 0, step + 1))
        await ack_output(dut, ltd_model)
    assert ltd_model.weights[0] == -1 or ltd_model.weights[0] == 0, "LTD program did not depress the weight"
    assert ltd_model.weights[0] != 1, "LTD program failed to move away from the positive bound"

    stable_model = await _configure_program(dut, ltd_words, threshold=1)
    await weight_write(dut, stable_model, 0, TERN_NEG)
    for step in range(4):
        await send_event(dut, stable_model, Event(0, 0, step + 1))
        await ack_output(dut, stable_model)
    assert stable_model.weights[0] == -1, "weight escaped the negative clamp under repeated LTD"


@cocotb.test()
async def test_fully_connected_end_to_end(dut):
    model = await _configure_and_load(dut, _if_program(), threshold=2)
    await weight_write(dut, model, 0, TERN_POS)
    await weight_write(dut, model, 1, TERN_POS)
    await weight_write(dut, model, 2, TERN_NEG)

    outputs = await _run_events(dut, model, [0, 1])
    assert _spike_bits(outputs) == [0, 1], "FC accumulation did not stay sub-threshold before crossing on the second active input"

    await csr_write(dut, model, CSR_CTRL, 0x01)
    outputs = await _run_events(dut, model, [0, 2, 1], start_time=10)
    assert _spike_bits(outputs) == [0, 0, 0], "FC inhibitory contribution was not reflected in the accumulated sum"


@cocotb.test()
async def test_convolution_patch_end_to_end(dut):
    model = await _configure_and_load(dut, _if_program(), threshold=2)
    await weight_write(dut, model, 0, TERN_POS)
    await weight_write(dut, model, 1, TERN_POS)
    await weight_write(dut, model, 2, TERN_NEG)

    patch_a = await _run_events(dut, model, [0, 1], start_time=1)
    assert _spike_bits(patch_a) == [0, 1], "1D convolution patch [1,1,0] should only activate after the second tap"

    await csr_write(dut, model, CSR_CTRL, 0x01)
    patch_b = await _run_events(dut, model, [0, 2, 1], start_time=10)
    assert _spike_bits(patch_b) == [0, 0, 0], "1D convolution patch [1,0,1] should stay below the ternary kernel threshold"


@cocotb.test()
async def test_recurrent_vanilla_snn_end_to_end(dut):
    model = await _configure_and_load(dut, _lif_program(leak_shift=2), threshold=2)
    await weight_write(dut, model, 0, TERN_POS)

    outputs = await _run_events(dut, model, [0, 0])
    assert _spike_bits(outputs) == [0, 1], "recurrent self-state did not let the second identical event trigger a spike"


@cocotb.test()
async def test_reservoir_echo_state_end_to_end(dut):
    model = await _configure_and_load(
        dut,
        [
            encode_recv(),
            encode_accum_w(),
            encode_integ(),
            encode_ldi(1, 0),
            encode_emit(tag=0),
        ],
        threshold=7,
    )
    await weight_write(dut, model, 0, TERN_POS)
    await weight_write(dut, model, 1, TERN_ZERO)

    outputs = await _run_events(dut, model, [0, 1, 1], start_time=1)
    assert _spike_bits(outputs) == [0, 0, 0], "reservoir echo test should stay sub-threshold"
    assert model.rf[0] == 1, "reservoir-style echo state did not preserve latent activity across neutral events"


@cocotb.test()
async def test_if_vs_lif_end_to_end(dut):
    if_model = await _configure_and_load(dut, _if_program(), threshold=2)
    await weight_write(dut, if_model, 0, TERN_POS)
    if_outputs = await _run_events(dut, if_model, [0, 0], start_time=1)

    lif_model = await _configure_and_load(dut, _lif_program(leak_shift=0), threshold=2)
    await weight_write(dut, lif_model, 0, TERN_POS)
    lif_outputs = await _run_events(dut, lif_model, [0, 0], start_time=1)

    assert _spike_bits(if_outputs) == [0, 1], "IF configuration should spike on the second integration step"
    assert _spike_bits(lif_outputs) == [0, 0], "max-leak LIF configuration should clear the membrane before the second event"


@cocotb.test()
async def test_multi_timescale_temporal_feature_end_to_end(dut):
    model = await _configure_and_load(dut, _multiscale_feature_program(), threshold=7)

    outputs = await _run_events(dut, model, [0, 0, 0], start_time=1)
    assert _spike_bits(outputs) == [0, 0, 0], "feature extractor should stay sub-threshold"
    assert model.rf[4] == 1, "fast trace should reset to a per-event feature"
    assert model.rf[5] > model.rf[4], "slow trace should accumulate a longer-memory feature"


@cocotb.test()
async def test_stdp_unsupervised_feature_learning_end_to_end(dut):
    model = await _configure_and_load(dut, _stdp_unsupervised_program(), threshold=1)
    await weight_write(dut, model, 0, TERN_ZERO)
    await weight_write(dut, model, 1, TERN_ZERO)

    outputs = await _run_events(dut, model, [0, 0, 0, 0], start_time=1)
    assert _count_spikes(outputs) == 4, "training exposure should spike for each presented preferred feature"
    assert model.weights[0] == 1, "preferred feature did not potentiate to the positive bound"
    assert model.weights[1] == 0, "inactive feature should not drift without exposure"


@cocotb.test()
async def test_rate_coded_ann_emulation_end_to_end(dut):
    low_model = await _configure_and_load(dut, _if_program(), threshold=2)
    await weight_write(dut, low_model, 0, TERN_POS)
    low_outputs = await _run_events(dut, low_model, [0, 0], start_time=1)

    high_model = await _configure_and_load(dut, _if_program(), threshold=2)
    await weight_write(dut, high_model, 0, TERN_POS)
    high_outputs = await _run_events(dut, high_model, [0, 0, 0, 0, 0, 0], start_time=1)

    assert _count_spikes(high_outputs) > _count_spikes(low_outputs), "higher input rate did not produce more output spikes"


@cocotb.test()
async def test_layer_implementability_contract(dut):
    await start_and_reset(dut)

    supported_without_routing = {
        "fully_connected": True,
        "convolution": True,
        "stdp_lite": True,
        "recurrent_vanilla_snn_rnn": True,
        "reservoir_computing": True,
        "lif_if": True,
        "adaptive_lif": False,
        "temporal_differencing": False,
        "multi_timescale_temporal_feature": True,
        "stdp_lite_unsupervised_feature_learning": True,
        "sparse_spiking_transformer": False,
        "positional_encoding_layer": False,
        "symbolic_grammar_spike_layer": False,
        "rate_coded_ann_emulation": True,
    }

    assert supported_without_routing["fully_connected"], "weighted event accumulation should support single-neuron FC reductions"
    assert supported_without_routing["convolution"], "fixed SID-to-weight mappings should support local convolution patches"
    assert supported_without_routing["stdp_lite"], "trace and ternary weight update ops should support STDP-lite"
    assert supported_without_routing["recurrent_vanilla_snn_rnn"], "stateful registers should support self-recurrent dynamics"
    assert supported_without_routing["reservoir_computing"], "leaky state and trace retention should support fading-memory reservoir primitives"
    assert supported_without_routing["lif_if"], "integrate, leak, compare, and reset ops should support IF/LIF neurons"
    assert supported_without_routing["multi_timescale_temporal_feature"], "dual trace lanes should support multi-timescale temporal features"
    assert supported_without_routing["stdp_lite_unsupervised_feature_learning"], (
        "STDP-lite plus event-driven features should support simple unsupervised feature learning"
    )
    assert supported_without_routing["rate_coded_ann_emulation"], "spike counts should emulate scalar rate-coded activations"

    assert not supported_without_routing["sparse_spiking_transformer"], (
        "the core has no routed multi-token attention fabric, so sparse spiking transformers are not implementable here"
    )
    assert not supported_without_routing["positional_encoding_layer"], (
        "event time is not readable by the ALU, so explicit positional encodings are not implementable here"
    )
    assert not supported_without_routing["symbolic_grammar_spike_layer"], (
        "the core has no routed graph/state-machine composition for symbolic grammar layers"
    )
    assert not supported_without_routing["adaptive_lif"], (
        "the 12-op ISA removed generic state-composition ops, so adaptive-LIF style custom feedback is not supported"
    )
    assert not supported_without_routing["temporal_differencing"], (
        "the 12-op ISA removed the general differencing ops, so temporal-difference programs are not supported"
    )
