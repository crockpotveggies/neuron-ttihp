# Programmable Neuron Tile Specification

This document describes the live RTL implementation of [tt_um_crockpotveggies_neuron.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/tt_um_crockpotveggies_neuron.sv).

The active design is a programmable, event-driven neuron core with:

- a TinyTapeout-facing wrapper
- a 4-bit saturating datapath
- a 16-entry ternary-clamped weight bank
- a 16-word microcode store
- a single-op microsequencer
- a reusable 2-entry event FIFO

The old primitive-composition architecture is no longer the active design.

## Active Module Structure

### Wrapper

- [tt_um_crockpotveggies_neuron.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/tt_um_crockpotveggies_neuron.sv)

The wrapper owns the TinyTapeout boundary:

- pin mapping
- synchronized input capture
- host request de-duplication
- command decode into `tt_cmd_t`
- forwarding the held output beat

### Reusable common blocks

- [tt_io_frontend.sv](/Users/justin/Projects/coldfoot_soc/hw/common/interfaces/tt_io_frontend.sv)
- [tt_event_decode.sv](/Users/justin/Projects/coldfoot_soc/hw/common/interfaces/tt_event_decode.sv)
- [tt_event_fifo.sv](/Users/justin/Projects/coldfoot_soc/hw/common/rv_fifo/tt_event_fifo.sv)
- [rv_if_t.vh](/Users/justin/Projects/coldfoot_soc/hw/common/struct/rv_if_t.vh)
- [event_types.vh](/Users/justin/Projects/coldfoot_soc/hw/common/packages/event_types.vh)

These are shared infrastructure for the wrapper boundary, event queue, and packed structs/constants.

### Core hierarchy

- [neuron.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron.sv)
- [neuron_csr.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_csr.sv)
- [neuron_ucode_store.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_ucode_store.sv)
- [neuron_weight_bank.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_weight_bank.sv)
- [neuron_state.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_state.sv)
- [neuron_exec.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_exec.sv)

`neuron.sv` is the core top. It owns the event scheduler and sequences one micro-op per cycle for each in-flight event.

## Execution Model

The design is event-driven, not free-running.

- `CMD_EVENT` pushes events into the 2-entry FIFO.
- If the FIFO is non-empty and no output beat is being held, the core starts servicing one event.
- The sequencer executes one micro-instruction per cycle.
- Intermediate state is kept in the core's working registers while the event is in flight.
- The architectural RF, metadata, output latch, and weight bank commit once, at the end of the event.

That gives the core:

- a smaller combinational cone than the older unrolled executor
- stable per-event semantics, because commit is still atomic

Important constraints:

- there is no branch instruction
- control flow is still only `vector_base[tag]` plus `ucode_len_r`
- the datapath step in `neuron_exec` is combinational, but the overall core is a clocked state machine

## Architectural State

### Register file

The core stores eight signed 4-bit registers:

- `R0 = V`
- `R1 = I`
- `R2 = TH`
- `R3 = R`
- `R4 = T0`
- `R5 = T1`
- `R6 = W`
- `R7 = AUX`

All arithmetic saturates to `-8..+7`.

### Non-RF state

The core also stores:

- `last_sid[3:0]`
- `last_tag[1:0]`
- `last_time[5:0]`
- `spike_flag`
- `have_out`
- `out_data_r[7:0]`

### Weight memory

[neuron_weight_bank.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_weight_bank.sv) stores 16 signed 4-bit entries, but the committed legal values are always ternary:

- `-1`
- `0`
- `+1`

Both direct host writes and `STDP_LITE` writeback are clamped into that set.

### Microcode memory

[neuron_ucode_store.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_ucode_store.sv) stores 16 words of 16 bits each.

- programming is byte-oriented through `CMD_UCODE`
- `ucode_ptr_r[0]` selects low vs high byte
- `ucode_ptr_r[4:1]` selects one of the 16 words

## Programming Surfaces

The core is programmed through:

- `CMD_CSR`
- `CMD_WEIGHT`
- `CMD_UCODE`

The event path (`CMD_EVENT`) only feeds the FIFO.

### CSR-owned state

[neuron_csr.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron_csr.sv) owns:

- `CSR_CTRL` pulse decode
- `ucode_ptr_r`
- `ucode_len_r`
- `vector_base0_r..vector_base3_r`
- `init_rf_flat`

Default reset image:

- `V = 0`
- `I = 0`
- `TH = +7`
- `R = 0`
- `T0 = 0`
- `T1 = 0`
- `W = 0`
- `AUX = 0`

## Reset And Enable Behavior

### Hard reset

- `rst_n = 0`

This clears:

- CSR state
- microcode store
- weight bank
- FIFO contents
- runtime neuron state

### Disable

- `ena = 0`

This clears runtime state aggressively:

- FIFO cleared
- weights cleared to zero
- `neuron_state` reloads `init_rf_flat`
- metadata cleared
- held output cleared

### Soft runtime reset

Triggered by `CSR_CTRL.bit0`.

This reloads the live runtime state from `init_rf_flat` and clears:

- `last_sid`, `last_tag`, `last_time`
- `spike_flag`

It does not erase microcode or the persistent weight bank.

### Output and FIFO clear pulses

`CSR_CTRL` also provides:

- `bit1`: clear held output beat
- `bit2`: clear the event FIFO

## Numeric And Transport Encodings

### Arithmetic precision

- RF values: signed 4-bit
- weight storage: signed 4-bit, ternary committed values
- event metadata: `sid[3:0]`, `tag[1:0]`, `event_time[5:0]`

### Host-side ternary weight encoding

- `00` -> `0`
- `01` -> `+1`
- `11` -> `-1`
- `10` -> treated as `0`

### Output beat format

`uo_out[7:0]` is the held output beat:

- `uo_out[7] = 1`
- `uo_out[6:5] = emitted tag`
- `uo_out[4:1] = last_sid`
- `uo_out[0] = spike_flag`

The beat is held until acknowledged on `uio_in[1]`.

## Notes On Time

`event_time` is captured by `RECV` and stored in `last_time`, but the current core does not automatically compute decay from timestamp deltas.

All decay remains explicit and shift-based:

- `LEAK`
- `TDEC`
- the non-spike decay branch of `REFRACT`

## Related Documentation

- [command_protocol.md](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/docs/command_protocol.md)
- [isa.md](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/docs/isa.md)
- [layer_examples.md](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/docs/layer_examples.md)
