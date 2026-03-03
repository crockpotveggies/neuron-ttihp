import cocotb

from ucode_common import (
    Event,
    ack_output,
    encode_emit,
    encode_recv,
    program_words,
    read_unsigned,
    send_event,
    start_and_reset,
    wait_output_valid,
    wait_ready,
)


@cocotb.test()
async def test_gl_program_and_emit_smoke(dut):
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
    await wait_output_valid(dut)
    expected = 0x80 | (2 << 5) | (6 << 1)
    observed = read_unsigned(dut.uo_out) & 0xFF
    assert observed == expected, f"GL smoke output mismatch: expected 0x{expected:02x}, got 0x{observed:02x}"

    await ack_output(dut, model)
    await wait_ready(dut)
