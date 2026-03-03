import random

import cocotb

from ucode_common import (
    CSR_CTRL,
    CSR_INIT_T01,
    CSR_INIT_TR,
    CSR_INIT_WAUX,
    CSR_VEC_BASE_01,
    Event,
    GoldenNeuron,
    OP_RECV,
    TERN_NEG,
    TERN_POS,
    ack_output,
    encode_accum_w,
    assert_model_matches,
    csr_write,
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
    read_unsigned,
    send_event,
    start_and_reset,
    weight_write,
)


def default_neuron_program() -> list[int]:
    return [
        encode_recv(),
        encode_accum_w(),
        encode_leak(1),
        encode_integ(),
        encode_ldi(1, 0),
        encode_spike_if_ge(),
        encode_reset(mode=1),
        encode_tdec0(1),
        encode_tinc0(1),
        encode_tdec1(1),
        encode_tinc1(1),
        encode_stdp(3),
        encode_emit(tag=0),
    ]


def assert_invariants(model: GoldenNeuron, context: str) -> None:
    for lane, value in enumerate(model.rf):
        assert -8 <= value <= 7, f"{context}: rf[{lane}] out of range"
    for lane, value in enumerate(model.weights):
        assert value in (-1, 0, 1), f"{context}: weight[{lane}] lost ternary clamp"
    assert len(model.fifo) <= 2, f"{context}: fifo depth exceeded 2"


async def configure_default_program(dut) -> GoldenNeuron:
    model = await start_and_reset(dut)
    await csr_write(dut, model, CSR_INIT_TR, 0x02)
    await csr_write(dut, model, CSR_INIT_T01, 0x11)
    await csr_write(dut, model, CSR_CTRL, 0x01)
    await program_words(dut, model, default_neuron_program(), base=0, vector_tag=0)
    await csr_write(dut, model, CSR_VEC_BASE_01, 0x00)
    for idx, code in enumerate((TERN_POS, TERN_NEG, TERN_POS, TERN_POS)):
        await weight_write(dut, model, idx, code)
    assert_model_matches(dut, model, "configure_default_program")
    return model


@cocotb.test()
async def test_randomized_differential_event_stream(dut):
    base_seed = 20260303
    for case_idx in range(3):
        rng = random.Random(base_seed + case_idx)
        model = await configure_default_program(dut)

        observed_outputs = []
        expected_outputs = []

        for step in range(12):
            event = Event(
                sid=rng.randint(0, 3),
                tag=0,
                event_time=(step + 1 + case_idx * 7) & 0x3F,
            )
            await send_event(dut, model, event)
            assert_invariants(model, f"random case {case_idx} step {step}")
            assert_model_matches(dut, model, f"random case {case_idx} step {step} after event")

            if model.have_out:
                expected_outputs.append(model.out_data)
                observed_outputs.append(await ack_output(dut, model))
                assert_model_matches(dut, model, f"random case {case_idx} step {step} after ack")

        assert observed_outputs == expected_outputs, f"random case {case_idx}: output stream mismatch"


@cocotb.test()
async def test_soft_reset_reloads_init_program_state(dut):
    model = await configure_default_program(dut)

    for step, sid in enumerate((0, 2, 3), start=1):
        await send_event(dut, model, Event(sid=sid, tag=0, event_time=step))
        if model.have_out:
            await ack_output(dut, model)

    await csr_write(dut, model, CSR_CTRL, 0x01)
    assert_model_matches(dut, model, "soft_reset")
    assert model.rf == model.init_rf, "soft reset did not restore init rf in the model"


@cocotb.test()
async def test_program_once_send_many_spikes_persistent_state(dut):
    model = await start_and_reset(dut)
    await csr_write(dut, model, CSR_INIT_TR, 0x02)
    await csr_write(dut, model, CSR_CTRL, 0x01)

    words = [
        encode_recv(),
        encode_accum_w(),
        encode_integ(),
        encode_ldi(1, 0),
        encode_spike_if_ge(),
        encode_emit(tag=0),
    ]

    await program_words(dut, model, words, base=0, vector_tag=0)
    await weight_write(dut, model, 0, TERN_POS)

    expected_ucode = model.ucode_mem.copy()
    expected_weights = model.weights.copy()
    expected_ucode_flat = 0
    for idx, word in enumerate(expected_ucode):
        expected_ucode_flat |= (word & 0xFFFF) << (idx * 16)

    outputs = []
    for step in range(4):
        await send_event(dut, model, Event(0, 0, step + 1))
        assert model.ucode_mem == expected_ucode, f"event {step}: microcode changed after programming"
        assert model.weights == expected_weights, f"event {step}: weights changed without a learning op"
        assert read_unsigned(dut.u_neuron.u_ucode_store.ucode_flat) == expected_ucode_flat, (
            f"event {step}: RTL microcode store changed unexpectedly"
        )
        assert_model_matches(dut, model, f"persistent event {step} after send")
        outputs.append(await ack_output(dut, model))
        assert model.ucode_mem == expected_ucode, f"event {step}: microcode changed after ack"
        assert model.weights == expected_weights, f"event {step}: weights changed after ack"
        assert_model_matches(dut, model, f"persistent event {step} after ack")

    assert [sample & 0x1 for sample in outputs] == [0, 1, 1, 1], "persistent non-resetting program did not accumulate spikes"

    await csr_write(dut, model, CSR_CTRL, 0x01)
    assert model.ucode_mem == expected_ucode, "soft reset should not erase programmed microcode"
    assert model.weights == expected_weights, "soft reset should not erase preset weights"
    assert_model_matches(dut, model, "persistent soft_reset")


@cocotb.test()
async def test_csr_init_waux_does_not_touch_weight_bank(dut):
    model = await start_and_reset(dut)
    await weight_write(dut, model, 0, TERN_NEG)
    await csr_write(dut, model, CSR_INIT_WAUX, 0x12)
    await csr_write(dut, model, CSR_CTRL, 0x01)

    assert_model_matches(dut, model, "csr_init_waux")
    assert model.rf[6] == 2, "CSR_INIT_WAUX did not preset W in the reset image"
    assert model.rf[7] == 1, "CSR_INIT_WAUX did not preset AUX in the reset image"
    assert model.weights[0] == -1, "CSR_INIT_WAUX must not overwrite the persistent weight bank"
