# Instruction Set And Microcode Format

This document describes the live microcode format and the current 12-instruction ISA implemented in [neuron_exec.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_exec.sv).

The core is a single-op microsequencer:

- one instruction executes per cycle while an event is in flight
- the sequencer walks a straight-line microprogram with no branch instruction
- the architectural state commits atomically once the final instruction of that event completes

This ISA is intentionally biased toward classic spiking layers and online learning. It keeps STDP-lite and trace maintenance, but it no longer includes the more CPU-like register-manipulation ops that were only needed for adaptive LIF, temporal differencing, and generic temporal scaling tricks.

## Datapath Conventions

The executor uses an 8-entry signed 4-bit register file:

- `R0 = V`
- `R1 = I`
- `R2 = TH`
- `R3 = R`
- `R4 = T0`
- `R5 = T1`
- `R6 = W`
- `R7 = AUX`

All arithmetic results saturate to `-8..+7`.

Outside the RF, the executor also carries:

- `last_sid`
- `last_tag`
- `last_time`
- `spike_flag`
- one pending weight write intent
- one pending emit intent

## Microcode Store

The core stores 16 instructions of 16 bits each.

- the start PC comes from `vector_base[tag]`
- the sequencer executes indices `0 .. ucode_len_r`
- `ucode_len_r = 0` means 1 active instruction
- `ucode_len_r = 15` means 16 active instructions

The micro-PC wraps modulo 16.

## Instruction Word Format

Each 16-bit word is decoded as:

- `op = word[15:11]`
- `rd = word[10:8]`
- `ra = word[7:5]`
- `rb = word[4:2]`
- `k = word[2:0]`

The encoding is compact and intentionally overlaps:

- `rb[0]` and `k[2]` both come from `word[2]`

The 4-bit signed immediate is built as:

- `imm4 = {rb[0], k[2:0]}`

Any undefined opcode slot is treated as a no-op.

## Execution Model Within One Event

Although the implementation is multi-cycle, the microcode semantics are still sequential:

- later instructions see earlier RF writes
- `ACCUM_W` and `STDP_LITE` see the pending shadow weight if one is already staged
- `EMIT` sees the current `spike_flag`

The key difference from the older multi-op chunks is timing only:

- one op per cycle
- same straight-line per-event semantics

## The 12 Instructions

### `0` `LDI rd, imm4`

- `rd = imm4`

This is the only remaining general register write. It is enough to clear `I`, seed a small constant, or bump a trace by a fixed literal.

### `1` `RECV`

Loads the current event metadata into:

- `last_sid = event.sid`
- `last_tag = event.tag`
- `last_time = event.event_time`

This is the only instruction that consumes the in-flight FIFO event payload directly.

### `2` `ACCUM_W`

Reads the weight selected by `last_sid` and updates the accumulator state:

- `R6 = weight[last_sid]`
- `R1 = sat4(R1 + weight[last_sid])`

If a prior instruction in the same event already staged a write to that same weight entry, `ACCUM_W` reads the pending shadow value rather than the committed bank value.

### `3` `LEAK sh`

Implicit target: `R0 = V`

- `V = sat4(V - (V >>> k[1:0]))`

### `4` `INTEG`

Implicit target: `R0 = V`

- `V = sat4(V + I)`

This is equivalent to `R0 = sat4(R0 + R1)`.

### `5` `SPIKE_IF_GE`

Implicit operands: `V` and `TH`

- `spike_flag = (V >= TH)`

This op only updates `spike_flag`.

### `6` `RESET mode`

Implicit target: `V`

Important: `RESET` is spike-conditional in the live RTL. It only changes `V` when `spike_flag = 1`.

Modes from `k[1:0]`:

- `00`: hard reset, `V = 0`
- `01`: subtractive reset, `V = sat4(V - TH)`
- `10`: clamp-to-threshold, `V = min(V, TH)`
- `11`: no-op

### `7` `REFRACT imm, sh`

Implicit target: `R`

Two behaviors:

- if `spike_flag = 1`, `R = imm4`
- otherwise, if `R > 0`, `R = sat4(R - (R >>> k[1:0]))`

### `8` `EMIT tag`

If no emit is already pending in the current event:

- `emit_pending = 1`
- `emit_data = {1'b1, k[1:0], last_sid, spike_flag}`

Only the first `EMIT` in an event is preserved.

### `9` `TDEC sel, sh`

Trace-select is carried in `rd[0]`:

- `0` selects `T0` (`R4`)
- `1` selects `T1` (`R5`)

Then:

- `Tsel = sat4(Tsel - (Tsel >>> k[1:0]))`

### `10` `TINC sel, imm`

Trace-select is carried in `rd[0]`:

- `0` selects `T0` (`R4`)
- `1` selects `T1` (`R5`)

Then:

- `Tsel = sat4(Tsel + imm4)`

### `11` `STDP_LITE mode`

Computes a ternary-safe writeback for `weight[last_sid]`.

Mode behavior from `k[1:0]`:

- `00`: hold
- `01`: if `spike_flag = 1` and `T0 > 0`, move one step positive
- `10`: if `spike_flag = 0` and `T1 > 0`, move one step negative
- `11`: compare `T0` and `T1`
  - if `T0 > T1`, move one step positive
  - if `T0 < T1`, move one step negative
  - if equal, hold

The writeback is always clamped to the ternary set `{-1, 0, +1}`.

## What Was Deliberately Removed

The earlier 16-op version included `MOV`, `ADD`, `SUB`, and `SHR`.

Those ops were removed to simplify the hardware while preserving:

- fully connected layers
- convolutional mappings
- basic recurrent / reservoir behavior
- IF / LIF dynamics
- unsupervised learning
- STDP-lite plasticity

What this cut does sacrifice:

- adaptive-LIF-style custom state composition
- temporal differencing programs
- generic temporal scaling on arbitrary registers

That is a deliberate trade: fewer mux-heavy general-purpose datapath features in exchange for a smaller, cleaner neuron-specific machine that still supports the learning-centric layer set this design targets.
