import copy
import os
from collections import deque
from dataclasses import dataclass, field

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadWrite, RisingEdge

CMD_CSR = 0b00
CMD_WEIGHT = 0b01
CMD_UCODE = 0b10
CMD_EVENT = 0b11

CSR_CTRL = 0x0
CSR_UCODE_PTR = 0x1
CSR_UCODE_LEN = 0x2
CSR_VEC_BASE_01 = 0x3
CSR_VEC_BASE_23 = 0x4
CSR_INIT_VI = 0x5
CSR_INIT_TR = 0x6
CSR_INIT_T01 = 0x7
CSR_INIT_WAUX = 0x8

OP_LDI = 0
OP_RECV = 1
OP_ACCUM_W = 2
OP_LEAK = 3
OP_INTEG = 4
OP_SPIKE_IF_GE = 5
OP_RESET = 6
OP_REFRACT = 7
OP_EMIT = 8
OP_TDEC = 9
OP_TINC = 10
OP_STDP_LITE = 11

# Compatibility aliases for legacy tests/program descriptions.
OP_RECV_W = OP_ACCUM_W

TERN_ZERO = 0b00
TERN_POS = 0b01
TERN_NEG = 0b11

CLOCK_PERIOD_NS = int(os.getenv("CLOCK_PERIOD_NS", "20"))
_CLOCK_TASKS = {}


def to_s4(value: int) -> int:
    value &= 0xF
    return value - 0x10 if value & 0x8 else value


def to_u4(value: int) -> int:
    return value & 0xF


def sat4(value: int) -> int:
    if value > 7:
        return 7
    if value < -8:
        return -8
    return value


def sign_extend_3(value: int) -> int:
    value &= 0x7
    return value - 0x8 if value & 0x4 else value


def imm4_from_k(k: int) -> int:
    return sign_extend_3(k & 0x7)


def imm3_to_s4(raw: int) -> int:
    return to_s4(((raw & 0x4) << 1) | (raw & 0x7))


def ternary_from_code(code: int) -> int:
    code &= 0x3
    if code == TERN_POS:
        return 1
    if code == TERN_NEG:
        return -1
    return 0


def ternary_clamp(value: int) -> int:
    if value > 0:
        return 1
    if value < 0:
        return -1
    return 0


def encode_ui(kind: int, addr_or_sid: int, low2: int = 0) -> int:
    return ((kind & 0x3) << 6) | ((addr_or_sid & 0xF) << 2) | (low2 & 0x3)


def encode_uio(high6: int = 0, in_req: int = 0, out_ack: int = 0) -> int:
    return ((high6 & 0x3F) << 2) | ((out_ack & 0x1) << 1) | (in_req & 0x1)


def read_unsigned(sig) -> int:
    return int(sig.value)


def read_signed(sig) -> int:
    width = len(sig)
    value = int(sig.value)
    sign_bit = 1 << (width - 1)
    return value - (1 << width) if value & sign_bit else value


def read_s4_field(value: int, lane: int) -> int:
    return to_s4((value >> (lane * 4)) & 0xF)


def pack_rf(regs: list[int]) -> int:
    flat = 0
    for lane, value in enumerate(regs):
        flat |= (to_u4(value) & 0xF) << (lane * 4)
    return flat


def unpack_rf(flat: int) -> list[int]:
    return [read_s4_field(flat, lane) for lane in range(8)]


def pack_event(event) -> int:
    return ((event.sid & 0xF) << 8) | ((event.tag & 0x3) << 6) | (event.event_time & 0x3F)


def unpack_event(bits: int):
    return Event((bits >> 8) & 0xF, (bits >> 6) & 0x3, bits & 0x3F)


def encode_rrr(op: int, rd: int = 0, ra: int = 0, rb: int = 0) -> int:
    return ((op & 0x1F) << 11) | ((rd & 0x7) << 8) | ((ra & 0x7) << 5) | ((rb & 0x7) << 2)


def encode_rr_shift(op: int, rd: int = 0, ra: int = 0, shift: int = 0) -> int:
    return ((op & 0x1F) << 11) | ((rd & 0x7) << 8) | ((ra & 0x7) << 5) | (shift & 0x3)


def encode_rd_shift(op: int, rd: int = 0, shift: int = 0) -> int:
    return ((op & 0x1F) << 11) | ((rd & 0x7) << 8) | (shift & 0x3)


def encode_signed_imm3(value: int) -> int:
    if value < -4 or value > 3:
        raise ValueError(f"3-bit signed immediate out of range: {value}")
    return value & 0x7


def encode_ldi(rd: int, imm: int) -> int:
    return ((OP_LDI & 0x1F) << 11) | ((rd & 0x7) << 8) | encode_signed_imm3(imm)


def encode_recv() -> int:
    return (OP_RECV & 0x1F) << 11


def encode_accum_w() -> int:
    return (OP_ACCUM_W & 0x1F) << 11


def encode_leak(shift: int) -> int:
    return ((OP_LEAK & 0x1F) << 11) | (shift & 0x3)


def encode_integ() -> int:
    return (OP_INTEG & 0x1F) << 11


def encode_spike_if_ge() -> int:
    return (OP_SPIKE_IF_GE & 0x1F) << 11


def encode_reset(mode: int, rd: int = 0) -> int:
    return ((OP_RESET & 0x1F) << 11) | ((rd & 0x7) << 8) | (mode & 0x3)


def encode_refract(imm: int, shift: int, rd: int = 0) -> int:
    k = encode_signed_imm3(imm)
    if (k & 0x3) != (shift & 0x3):
        raise ValueError("REFRACT encodes shift in the same low bits as the signed immediate")
    return ((OP_REFRACT & 0x1F) << 11) | ((rd & 0x7) << 8) | k


def encode_emit(tag: int = 0) -> int:
    return ((OP_EMIT & 0x1F) << 11) | (tag & 0x3)


def encode_tdec(sel: int, shift: int) -> int:
    return ((OP_TDEC & 0x1F) << 11) | ((sel & 0x1) << 8) | (shift & 0x3)


def encode_tinc(sel: int, imm: int) -> int:
    return ((OP_TINC & 0x1F) << 11) | ((sel & 0x1) << 8) | encode_signed_imm3(imm)


def encode_tdec0(shift: int) -> int:
    return encode_tdec(0, shift)


def encode_tdec1(shift: int) -> int:
    return encode_tdec(1, shift)


def encode_tinc0(imm: int) -> int:
    return encode_tinc(0, imm)


def encode_tinc1(imm: int) -> int:
    return encode_tinc(1, imm)


def encode_stdp(mode: int) -> int:
    return ((OP_STDP_LITE & 0x1F) << 11) | (mode & 0x3)


@dataclass(frozen=True)
class Event:
    sid: int
    tag: int = 0
    event_time: int = 0


@dataclass
class CommitLog:
    event: Event
    pre_rf: list[int]
    post_rf: list[int]
    pre_last_sid: int
    post_last_sid: int
    pre_last_tag: int
    post_last_tag: int
    pre_last_time: int
    post_last_time: int
    pre_cmp_ge: int
    post_cmp_ge: int
    pre_cmp_eq: int
    post_cmp_eq: int
    pre_spike_flag: int
    post_spike_flag: int
    weight_wr_en: int
    weight_wr_idx: int
    weight_wr_value: int
    emitted: int
    emit_data: int


@dataclass
class GoldenNeuron:
    ucode_ptr: int = 0
    ucode_len: int = 0
    vector_bases: list[int] = field(default_factory=lambda: [0, 0, 0, 0])
    init_rf: list[int] = field(default_factory=lambda: [0, 0, 7, 0, 0, 0, 0, 0])
    rf: list[int] = field(default_factory=lambda: [0, 0, 7, 0, 0, 0, 0, 0])
    ucode_mem: list[int] = field(default_factory=lambda: [0] * 16)
    weights: list[int] = field(default_factory=lambda: [0] * 16)
    last_sid: int = 0
    last_tag: int = 0
    last_time: int = 0
    cmp_ge: int = 0
    cmp_eq: int = 0
    spike_flag: int = 0
    have_out: int = 0
    out_data: int = 0
    fifo: deque = field(default_factory=lambda: deque([], maxlen=2))

    def clone(self):
        return copy.deepcopy(self)

    def reset_runtime(self) -> None:
        self.rf = self.init_rf.copy()
        self.last_sid = 0
        self.last_tag = 0
        self.last_time = 0
        self.cmp_ge = 0
        self.cmp_eq = 0
        self.spike_flag = 0

    def reset_all(self) -> None:
        self.ucode_ptr = 0
        self.ucode_len = 0
        self.vector_bases = [0, 0, 0, 0]
        self.init_rf = [0, 0, 7, 0, 0, 0, 0, 0]
        self.rf = self.init_rf.copy()
        self.ucode_mem = [0] * 16
        self.weights = [0] * 16
        self.last_sid = 0
        self.last_tag = 0
        self.last_time = 0
        self.cmp_ge = 0
        self.cmp_eq = 0
        self.spike_flag = 0
        self.have_out = 0
        self.out_data = 0
        self.fifo.clear()

    def _service_until_blocked(self) -> None:
        while not self.have_out and self.fifo:
            self.service_once()

    def csr_write(self, addr: int, data: int) -> None:
        addr &= 0xF
        data &= 0xFF

        if addr == CSR_CTRL:
            if data & 0x2:
                self.have_out = 0
                self.out_data = 0
            if data & 0x1:
                self.reset_runtime()
            if data & 0x4:
                self.fifo.clear()
        elif addr == CSR_UCODE_PTR:
            self.ucode_ptr = data & 0x1F
        elif addr == CSR_UCODE_LEN:
            self.ucode_len = data & 0xF
        elif addr == CSR_VEC_BASE_01:
            self.vector_bases[0] = data & 0xF
            self.vector_bases[1] = (data >> 4) & 0xF
        elif addr == CSR_VEC_BASE_23:
            self.vector_bases[2] = data & 0xF
            self.vector_bases[3] = (data >> 4) & 0xF
        elif addr == CSR_INIT_VI:
            self.init_rf[0] = to_s4(data & 0xF)
            self.init_rf[1] = to_s4((data >> 4) & 0xF)
        elif addr == CSR_INIT_TR:
            self.init_rf[2] = to_s4(data & 0xF)
            self.init_rf[3] = to_s4((data >> 4) & 0xF)
        elif addr == CSR_INIT_T01:
            self.init_rf[4] = to_s4(data & 0xF)
            self.init_rf[5] = to_s4((data >> 4) & 0xF)
        elif addr == CSR_INIT_WAUX:
            self.init_rf[6] = to_s4(data & 0xF)
            self.init_rf[7] = to_s4((data >> 4) & 0xF)

        self._service_until_blocked()

    def ucode_write(self, data: int) -> None:
        lane = (self.ucode_ptr >> 1) & 0xF
        data &= 0xFF
        if self.ucode_ptr & 0x1:
            self.ucode_mem[lane] = (self.ucode_mem[lane] & 0x00FF) | (data << 8)
        else:
            self.ucode_mem[lane] = (self.ucode_mem[lane] & 0xFF00) | data
        self.ucode_ptr = (self.ucode_ptr + 1) & 0x1F
        self._service_until_blocked()

    def program_words(self, words: list[int], base: int = 0) -> None:
        self.csr_write(CSR_UCODE_PTR, (base * 2) & 0x1F)
        for word in words:
            self.ucode_write(word & 0xFF)
            self.ucode_write((word >> 8) & 0xFF)
        self.csr_write(CSR_UCODE_LEN, max(0, len(words) - 1))

    def weight_write(self, idx: int, code: int) -> None:
        self.weights[idx & 0xF] = ternary_clamp(ternary_from_code(code))
        self._service_until_blocked()

    def can_accept_event(self) -> bool:
        return (not self.have_out) and (len(self.fifo) < 2)

    def push_event(self, event: Event) -> None:
        if not self.can_accept_event():
            raise RuntimeError("event push while blocked")
        self.fifo.append(Event(event.sid & 0xF, event.tag & 0x3, event.event_time & 0x3F))
        self._service_until_blocked()

    def ack_output(self) -> int:
        if not self.have_out:
            raise RuntimeError("ack without output")
        data = self.out_data & 0xFF
        self.have_out = 0
        self.out_data = 0
        self._service_until_blocked()
        return data

    def service_once(self) -> CommitLog:
        if self.have_out or not self.fifo:
            raise RuntimeError("service_once called while blocked")

        event = self.fifo.popleft()
        rf = self.rf.copy()
        last_sid_next = self.last_sid
        last_tag_next = self.last_tag
        last_time_next = self.last_time
        cmp_ge_next = self.cmp_ge
        cmp_eq_next = self.cmp_eq
        spike_flag_next = self.spike_flag
        weight_wr_en = 0
        weight_wr_idx = self.last_sid
        weight_wr_value = 0
        emit_pending = 0
        emit_data = 0
        exec_base = self.vector_bases[event.tag & 0x3]

        for step in range(16):
            if step > self.ucode_len:
                continue

            word = self.ucode_mem[(exec_base + step) & 0xF]
            op = (word >> 11) & 0x1F
            rd = (word >> 8) & 0x7
            ra = (word >> 5) & 0x7
            rb = (word >> 2) & 0x7
            k = word & 0x7
            imm4 = imm4_from_k(k)

            def reg(lane: int) -> int:
                return rf[lane & 0x7]

            def set_reg(lane: int, value: int) -> None:
                rf[lane & 0x7] = to_s4(value)

            def select_weight_shadow() -> int:
                if weight_wr_en and weight_wr_idx == (last_sid_next & 0xF):
                    return ternary_clamp(weight_wr_value)
                return self.weights[last_sid_next & 0xF]

            if op == OP_LDI:
                set_reg(rd, imm4)
            elif op == OP_RECV:
                last_sid_next = event.sid & 0xF
                last_tag_next = event.tag & 0x3
                last_time_next = event.event_time & 0x3F
            elif op == OP_ACCUM_W:
                weight_shadow = select_weight_shadow()
                set_reg(6, weight_shadow)
                set_reg(1, sat4(reg(1) + weight_shadow))
            elif op == OP_LEAK:
                set_reg(0, sat4(reg(0) - (reg(0) >> (k & 0x3))))
            elif op == OP_INTEG:
                set_reg(0, sat4(reg(0) + reg(1)))
            elif op == OP_SPIKE_IF_GE:
                spike_flag_next = int(reg(0) >= reg(2))
            elif op == OP_RESET:
                mode = k & 0x3
                if spike_flag_next:
                    if mode == 0:
                        set_reg(0, 0)
                    elif mode == 1:
                        set_reg(0, sat4(reg(0) - reg(2)))
                    elif mode == 2 and reg(0) > reg(2):
                        set_reg(0, reg(2))
            elif op == OP_REFRACT:
                if spike_flag_next:
                    set_reg(3, imm4)
                elif reg(3) > 0:
                    set_reg(3, sat4(reg(3) - (reg(3) >> (k & 0x3))))
            elif op == OP_EMIT:
                if not emit_pending:
                    emit_pending = 1
                    emit_data = 0x80 | ((k & 0x3) << 5) | ((last_sid_next & 0xF) << 1) | (spike_flag_next & 0x1)
            elif op == OP_TDEC:
                lane = 5 if (rd & 0x1) else 4
                set_reg(lane, sat4(reg(lane) - (reg(lane) >> (k & 0x3))))
            elif op == OP_TINC:
                lane = 5 if (rd & 0x1) else 4
                set_reg(lane, sat4(reg(lane) + imm4))
            elif op == OP_STDP_LITE:
                weight_shadow = select_weight_shadow()
                trace_cmp = reg(4) - reg(5)
                mode = k & 0x3
                if mode == 1:
                    if spike_flag_next and reg(4) > 0:
                        weight_shadow = ternary_clamp(weight_shadow + 1)
                elif mode == 2:
                    if (not spike_flag_next) and reg(5) > 0:
                        weight_shadow = ternary_clamp(weight_shadow - 1)
                elif mode == 3:
                    if trace_cmp > 0:
                        weight_shadow = ternary_clamp(weight_shadow + 1)
                    elif trace_cmp < 0:
                        weight_shadow = ternary_clamp(weight_shadow - 1)
                weight_wr_en = 1
                weight_wr_idx = last_sid_next & 0xF
                weight_wr_value = ternary_clamp(weight_shadow)
            else:
                pass

        log = CommitLog(
            event=event,
            pre_rf=self.rf.copy(),
            post_rf=rf.copy(),
            pre_last_sid=self.last_sid,
            post_last_sid=last_sid_next,
            pre_last_tag=self.last_tag,
            post_last_tag=last_tag_next,
            pre_last_time=self.last_time,
            post_last_time=last_time_next,
            pre_cmp_ge=self.cmp_ge,
            post_cmp_ge=cmp_ge_next,
            pre_cmp_eq=self.cmp_eq,
            post_cmp_eq=cmp_eq_next,
            pre_spike_flag=self.spike_flag,
            post_spike_flag=spike_flag_next,
            weight_wr_en=weight_wr_en,
            weight_wr_idx=weight_wr_idx,
            weight_wr_value=ternary_clamp(weight_wr_value),
            emitted=emit_pending,
            emit_data=emit_data & 0xFF,
        )

        self.rf = rf
        self.last_sid = last_sid_next
        self.last_tag = last_tag_next
        self.last_time = last_time_next
        self.cmp_ge = cmp_ge_next
        self.cmp_eq = cmp_eq_next
        self.spike_flag = spike_flag_next
        if weight_wr_en:
            self.weights[weight_wr_idx & 0xF] = ternary_clamp(weight_wr_value)
        if emit_pending:
            self.have_out = 1
            self.out_data = emit_data & 0xFF
        return log


async def ensure_clock_started(dut) -> None:
    key = id(dut)
    if key in _CLOCK_TASKS:
        _CLOCK_TASKS[key].kill()
    _CLOCK_TASKS[key] = cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())


async def start_and_reset(dut) -> GoldenNeuron:
    await ensure_clock_started(dut)
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await wait_ready(dut)
    return GoldenNeuron()


async def wait_ready(dut, timeout_cycles: int = 50) -> None:
    for _ in range(timeout_cycles):
        if read_unsigned(dut.uio_out) & 0x1:
            return
        await RisingEdge(dut.clk)
    raise RuntimeError("timeout waiting for ready")


async def wait_not_ready(dut, timeout_cycles: int = 50) -> None:
    for _ in range(timeout_cycles):
        if (read_unsigned(dut.uio_out) & 0x1) == 0:
            return
        await RisingEdge(dut.clk)
    raise RuntimeError("timeout waiting for ready to drop")


async def wait_output_valid(dut, timeout_cycles: int = 50) -> None:
    for _ in range(timeout_cycles):
        if (read_unsigned(dut.uio_out) >> 1) & 0x1:
            return
        await RisingEdge(dut.clk)
    raise RuntimeError("timeout waiting for output valid")


async def wait_event_commit(dut, timeout_cycles: int = 50) -> None:
    await RisingEdge(dut.clk)
    for _ in range(timeout_cycles):
        if read_unsigned(dut.u_neuron.busy_r) == 0:
            await ReadWrite()
            return
        await RisingEdge(dut.clk)
    raise RuntimeError("timeout waiting for event commit")


async def wait_frontend_idle(dut) -> None:
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await wait_ready(dut)


async def issue_command(dut, kind: int, addr_or_sid: int, data: int = 0, wait_rearm: bool = True) -> None:
    await wait_frontend_idle(dut)
    target_ui = encode_ui(kind, addr_or_sid, data & 0x3)
    target_uio = encode_uio((data >> 2) & 0x3F, in_req=1, out_ack=0)
    dut.ui_in.value = target_ui
    dut.uio_in.value = target_uio
    for _ in range(100):
        if read_unsigned(dut.ui_in_sync) == target_ui and read_unsigned(dut.uio_in_sync) == target_uio:
            break
        await RisingEdge(dut.clk)
    else:
        raise RuntimeError(f"timeout syncing command kind={kind} addr={addr_or_sid}")
    await RisingEdge(dut.clk)
    for _ in range(100):
        if (read_unsigned(dut.uio_out) & 0x1) == 0:
            break
        await RisingEdge(dut.clk)
    else:
        raise RuntimeError(f"timeout waiting for command accept kind={kind} addr={addr_or_sid}")
    dut.uio_in.value = encode_uio(0, in_req=0, out_ack=0)
    dut.ui_in.value = 0
    if wait_rearm:
        for _ in range(100):
            if read_unsigned(dut.ui_in_sync) == 0 and read_unsigned(dut.uio_in_sync) == 0:
                break
            await RisingEdge(dut.clk)
        else:
            raise RuntimeError(f"timeout draining command kind={kind} addr={addr_or_sid}")
        for _ in range(100):
            if read_unsigned(dut.uio_out) & 0x1:
                break
            await RisingEdge(dut.clk)
        else:
            raise RuntimeError(f"timeout waiting for command rearm kind={kind} addr={addr_or_sid}")


async def csr_write(dut, model: GoldenNeuron, addr: int, data: int) -> None:
    await issue_command(dut, CMD_CSR, addr, data)
    model.csr_write(addr, data)


async def weight_write(dut, model: GoldenNeuron, idx: int, code: int) -> None:
    await issue_command(dut, CMD_WEIGHT, idx, code & 0x3)
    model.weight_write(idx, code)


async def ucode_write_byte(dut, model: GoldenNeuron, data: int) -> None:
    await issue_command(dut, CMD_UCODE, 0, data)
    assert read_unsigned(dut.u_neuron.u_csr.ucode_prog_data) == (data & 0xFF), (
        f"ucode_write_byte data mismatch: expected 0x{data & 0xFF:02x}, "
        f"got 0x{read_unsigned(dut.u_neuron.u_csr.ucode_prog_data) & 0xFF:02x}"
    )
    model.ucode_write(data)


async def program_words(dut, model: GoldenNeuron, words: list[int], base: int = 0, vector_tag: int = 0) -> None:
    await csr_write(dut, model, CSR_UCODE_PTR, (base * 2) & 0x1F)
    for word in words:
        await ucode_write_byte(dut, model, word & 0xFF)
        await ucode_write_byte(dut, model, (word >> 8) & 0xFF)
    await csr_write(dut, model, CSR_UCODE_LEN, max(0, len(words) - 1))
    if vector_tag in (0, 1):
        current = (model.vector_bases[1] << 4) | model.vector_bases[0]
        next_val = (base << 4) | (current & 0xF) if vector_tag == 1 else ((current & 0xF0) | (base & 0xF))
        await csr_write(dut, model, CSR_VEC_BASE_01, next_val)
    else:
        current = (model.vector_bases[3] << 4) | model.vector_bases[2]
        next_val = (base << 4) | (current & 0xF) if vector_tag == 3 else ((current & 0xF0) | (base & 0xF))
        await csr_write(dut, model, CSR_VEC_BASE_23, next_val)
    await ReadWrite()
    flat = read_unsigned(dut.u_neuron.u_ucode_store.ucode_flat)
    for idx in range(len(words)):
        actual = (flat >> (((base + idx) & 0xF) * 16)) & 0xFFFF
        expected = model.ucode_mem[(base + idx) & 0xF] & 0xFFFF
        assert actual == expected, (
            f"program_words word {(base + idx) & 0xF}: expected 0x{expected:04x}, got 0x{actual:04x}"
        )


def _pack_init_byte(lo: int, hi: int) -> int:
    return (to_u4(lo) & 0xF) | ((to_u4(hi) & 0xF) << 4)


async def write_init_rf(dut, model: GoldenNeuron, regs: list[int]) -> None:
    if len(regs) != 8:
        raise ValueError("write_init_rf expects 8 register values")
    await csr_write(dut, model, CSR_INIT_VI, _pack_init_byte(regs[0], regs[1]))
    await csr_write(dut, model, CSR_INIT_TR, _pack_init_byte(regs[2], regs[3]))
    await csr_write(dut, model, CSR_INIT_T01, _pack_init_byte(regs[4], regs[5]))
    await csr_write(dut, model, CSR_INIT_WAUX, _pack_init_byte(regs[6], regs[7]))


async def soft_reset_runtime(dut, model: GoldenNeuron) -> None:
    await csr_write(dut, model, CSR_CTRL, 0x01)


async def send_event(dut, model: GoldenNeuron, event: Event, wait_for_service: bool = True) -> None:
    await issue_command(
        dut,
        CMD_EVENT,
        event.sid & 0xF,
        ((event.event_time & 0x3F) << 2) | (event.tag & 0x3),
        wait_rearm=wait_for_service,
    )
    model.push_event(event)


async def send_event_capture_preview(dut, event: Event) -> None:
    await wait_frontend_idle(dut)
    target_ui = encode_ui(CMD_EVENT, event.sid & 0xF, event.tag & 0x3)
    target_uio = encode_uio(event.event_time & 0x3F, in_req=1, out_ack=0)
    dut.ui_in.value = target_ui
    dut.uio_in.value = target_uio
    for _ in range(100):
        if read_unsigned(dut.ui_in_sync) == target_ui and read_unsigned(dut.uio_in_sync) == target_uio:
            break
        await RisingEdge(dut.clk)
    else:
        raise RuntimeError(f"timeout syncing event sid={event.sid}")
    await RisingEdge(dut.clk)
    for _ in range(100):
        if (read_unsigned(dut.uio_out) & 0x1) == 0:
            break
        await RisingEdge(dut.clk)
    else:
        raise RuntimeError(f"timeout waiting for event accept sid={event.sid}")
    dut.uio_in.value = 0
    dut.ui_in.value = 0
    await ReadWrite()


async def ack_output(dut, model: GoldenNeuron) -> int:
    await wait_output_valid(dut)
    observed = read_unsigned(dut.uo_out) & 0xFF
    dut.uio_in.value = encode_uio(0, in_req=0, out_ack=1)
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    for _ in range(100):
        if (read_unsigned(dut.uio_in_sync) >> 1) & 0x1:
            break
        await RisingEdge(dut.clk)
    else:
        raise RuntimeError("timeout waiting for synchronized output ack")
    await RisingEdge(dut.clk)
    expected = model.ack_output()
    assert observed == expected, f"ack_output: expected 0x{expected:02x}, got 0x{observed:02x}"
    return observed


def snapshot_dut(dut) -> dict:
    fifo = []
    if read_unsigned(dut.u_neuron.u_event_fifo.slot0_valid):
        fifo.append(unpack_event(read_unsigned(dut.u_neuron.u_event_fifo.slot0_data)))
    if read_unsigned(dut.u_neuron.u_event_fifo.slot1_valid):
        fifo.append(unpack_event(read_unsigned(dut.u_neuron.u_event_fifo.slot1_data)))

    weights = [read_s4_field(read_unsigned(dut.u_neuron.u_weight_bank.weight_flat), lane) for lane in range(16)]
    rf_flat = read_unsigned(dut.u_neuron.u_state.rf_state_flat)
    return {
        "rf": unpack_rf(rf_flat),
        "rf_flat": rf_flat,
        "last_sid": read_unsigned(dut.u_neuron.u_state.last_sid_r),
        "last_tag": read_unsigned(dut.u_neuron.u_state.last_tag_r),
        "last_time": read_unsigned(dut.u_neuron.u_state.last_time_r),
        "cmp_ge": read_unsigned(dut.u_neuron.u_state.cmp_ge_r),
        "cmp_eq": read_unsigned(dut.u_neuron.u_state.cmp_eq_r),
        "spike_flag": read_unsigned(dut.u_neuron.u_state.spike_flag_r),
        "have_out": read_unsigned(dut.u_neuron.u_state.have_out_r),
        "out_data": read_unsigned(dut.u_neuron.u_state.out_data_r) & 0xFF,
        "weights": weights,
        "fifo": fifo,
        "ucode_ptr": read_unsigned(dut.u_neuron.u_csr.ucode_ptr_r),
        "ucode_len": read_unsigned(dut.u_neuron.u_csr.ucode_len_r),
        "vector_bases": [
            read_unsigned(dut.u_neuron.u_csr.vector_base0_r),
            read_unsigned(dut.u_neuron.u_csr.vector_base1_r),
            read_unsigned(dut.u_neuron.u_csr.vector_base2_r),
            read_unsigned(dut.u_neuron.u_csr.vector_base3_r),
        ],
        "init_rf": unpack_rf(read_unsigned(dut.u_neuron.u_csr.init_rf_flat)),
    }


def assert_model_matches(dut, model: GoldenNeuron, context: str) -> None:
    snap = snapshot_dut(dut)
    assert snap["rf"] == model.rf, f"{context}: rf mismatch {snap['rf']} != {model.rf}"
    assert snap["last_sid"] == model.last_sid, f"{context}: last_sid"
    assert snap["last_tag"] == model.last_tag, f"{context}: last_tag"
    assert snap["last_time"] == model.last_time, f"{context}: last_time"
    assert snap["cmp_ge"] == model.cmp_ge, f"{context}: cmp_ge"
    assert snap["cmp_eq"] == model.cmp_eq, f"{context}: cmp_eq"
    assert snap["spike_flag"] == model.spike_flag, f"{context}: spike_flag"
    assert snap["have_out"] == model.have_out, f"{context}: have_out"
    assert snap["out_data"] == (model.out_data & 0xFF), f"{context}: out_data"
    assert snap["weights"] == model.weights, f"{context}: weight bank mismatch"
    assert snap["ucode_ptr"] == model.ucode_ptr, f"{context}: ucode_ptr"
    assert snap["ucode_len"] == model.ucode_len, f"{context}: ucode_len"
    assert snap["vector_bases"] == model.vector_bases, f"{context}: vector_bases"
    assert snap["init_rf"] == model.init_rf, f"{context}: init_rf"
    assert snap["fifo"] == list(model.fifo), f"{context}: fifo mismatch"


def _set_weight_mem(dut, idx: int, value: int) -> None:
    dut.u_neuron.u_weight_bank.weight_mem[idx].value = to_u4(ternary_clamp(value))


def _set_ucode_mem(dut, idx: int, value: int) -> None:
    dut.u_neuron.u_ucode_store.ucode_mem[idx].value = value & 0xFFFF


def force_runtime(dut, model: GoldenNeuron) -> None:
    dut.u_neuron.u_state.rf_state_flat.value = pack_rf(model.rf)
    dut.u_neuron.u_state.last_sid_r.value = model.last_sid & 0xF
    dut.u_neuron.u_state.last_tag_r.value = model.last_tag & 0x3
    dut.u_neuron.u_state.last_time_r.value = model.last_time & 0x3F
    dut.u_neuron.u_state.cmp_ge_r.value = model.cmp_ge & 0x1
    dut.u_neuron.u_state.cmp_eq_r.value = model.cmp_eq & 0x1
    dut.u_neuron.u_state.spike_flag_r.value = model.spike_flag & 0x1
    dut.u_neuron.u_state.have_out_r.value = model.have_out & 0x1
    dut.u_neuron.u_state.out_data_r.value = model.out_data & 0xFF
    dut.u_neuron.u_csr.ucode_ptr_r.value = model.ucode_ptr & 0x1F
    dut.u_neuron.u_csr.ucode_len_r.value = model.ucode_len & 0xF
    dut.u_neuron.u_csr.vector_base0_r.value = model.vector_bases[0] & 0xF
    dut.u_neuron.u_csr.vector_base1_r.value = model.vector_bases[1] & 0xF
    dut.u_neuron.u_csr.vector_base2_r.value = model.vector_bases[2] & 0xF
    dut.u_neuron.u_csr.vector_base3_r.value = model.vector_bases[3] & 0xF
    dut.u_neuron.u_csr.init_rf_flat.value = pack_rf(model.init_rf)
    dut.u_neuron.u_event_fifo.slot0_valid.value = 1 if len(model.fifo) >= 1 else 0
    dut.u_neuron.u_event_fifo.slot0_data.value = pack_event(model.fifo[0]) if len(model.fifo) >= 1 else 0
    dut.u_neuron.u_event_fifo.slot1_valid.value = 1 if len(model.fifo) >= 2 else 0
    dut.u_neuron.u_event_fifo.slot1_data.value = pack_event(model.fifo[1]) if len(model.fifo) >= 2 else 0
    for idx, weight in enumerate(model.weights):
        _set_weight_mem(dut, idx, weight)
    for idx, word in enumerate(model.ucode_mem):
        _set_ucode_mem(dut, idx, word)


async def prime_single_step(dut, model: GoldenNeuron, event: Event) -> None:
    model.fifo.clear()
    model.have_out = 0
    model.out_data = 0
    model.fifo.append(event)
    force_runtime(dut, model)
    await ReadWrite()
    assert read_unsigned(dut.u_neuron.fifo_pop) == 1, "single-step harness did not present fifo_pop"


def snapshot_commit_preview(dut) -> dict:
    return {
        "rf_next_flat": read_unsigned(dut.u_neuron.u_exec.rf_next_flat),
        "last_sid_next": read_unsigned(dut.u_neuron.u_exec.last_sid_next),
        "last_tag_next": read_unsigned(dut.u_neuron.u_exec.last_tag_next),
        "last_time_next": read_unsigned(dut.u_neuron.u_exec.last_time_next),
        "cmp_ge_next": read_unsigned(dut.u_neuron.u_exec.cmp_ge_next),
        "cmp_eq_next": read_unsigned(dut.u_neuron.u_exec.cmp_eq_next),
        "spike_flag_next": read_unsigned(dut.u_neuron.u_exec.spike_flag_next),
        "weight_wr_en_next": read_unsigned(dut.u_neuron.u_exec.weight_wr_en_next),
        "weight_wr_idx_next": read_unsigned(dut.u_neuron.u_exec.weight_wr_idx_next),
        "weight_wr_value_next": read_signed(dut.u_neuron.u_exec.weight_wr_value_next),
        "emit_pending_next": read_unsigned(dut.u_neuron.u_exec.emit_pending_next),
        "emit_data_next": read_unsigned(dut.u_neuron.u_exec.emit_data_next) & 0xFF,
    }


def assert_commit_matches(preview: dict, expected: CommitLog, context: str) -> None:
    assert unpack_rf(preview["rf_next_flat"]) == expected.post_rf, f"{context}: rf_next"
    assert preview["last_sid_next"] == expected.post_last_sid, f"{context}: last_sid_next"
    assert preview["last_tag_next"] == expected.post_last_tag, f"{context}: last_tag_next"
    assert preview["last_time_next"] == expected.post_last_time, f"{context}: last_time_next"
    assert preview["cmp_ge_next"] == expected.post_cmp_ge, f"{context}: cmp_ge_next"
    assert preview["cmp_eq_next"] == expected.post_cmp_eq, f"{context}: cmp_eq_next"
    assert preview["spike_flag_next"] == expected.post_spike_flag, f"{context}: spike_flag_next"
    if preview["weight_wr_en_next"] and expected.weight_wr_en:
        assert preview["weight_wr_idx_next"] == expected.weight_wr_idx, f"{context}: weight_wr_idx_next"
        assert preview["weight_wr_value_next"] == expected.weight_wr_value, f"{context}: weight_wr_value_next"
    assert preview["emit_pending_next"] == expected.emitted, f"{context}: emit_pending_next"
    assert preview["emit_data_next"] == (expected.emit_data & 0xFF), f"{context}: emit_data_next"
