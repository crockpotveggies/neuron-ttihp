# Command Protocol

This document describes how to drive the live `tt_um_crockpotveggies_neuron` wrapper through the TinyTapeout pins.

The current protocol is a request/ready interface at the wrapper boundary. The wrapper synchronizes the external pins, de-duplicates the input request, decodes a `tt_cmd_t`, and forwards that command to the programmable neuron core.

## 1. Pin Map

### Inputs

- `ui_in[7:0]`: primary command payload byte
- `uio_in[0]`: input request / command valid
- `uio_in[1]`: output acknowledge
- `uio_in[7:2]`: sideband payload

### Outputs

- `uo_out[7:0]`: held output beat from the neuron core
- `uio_out[0]`: wrapper ready for the next command
- `uio_out[1]`: output valid
- `uio_out[7:2]`: always `0`
- `uio_oe[1:0] = 1`, `uio_oe[7:2] = 0`

## 2. Input Handshake Rules

The live wrapper accepts exactly one command per assertion of `uio_in[0]`.

Host-side sequence:

1. Drive `ui_in` and `uio_in[7:2]` with the desired command payload.
2. Assert `uio_in[0]`.
3. Hold the payload stable until `uio_out[0]` is observed high.
4. Deassert `uio_in[0]`.
5. Only then begin the next command.

Important behavior:

- The wrapper internally synchronizes the incoming pins before latching a command.
- `in_req_seen` blocks duplicate acceptance while `uio_in[0]` remains high.
- Holding `uio_in[0]` high after acceptance will not enqueue repeated commands.
- A new command requires a fresh low-to-high transition of `uio_in[0]`.

## 3. Output Handshake Rules

The core emits one held output beat at a time.

Host-side sequence:

1. Wait for `uio_out[1] = 1`.
2. Read `uo_out[7:0]`.
3. Assert `uio_in[1]` to acknowledge the beat.

The core will keep `uo_out[7:0]` stable until it sees `uio_in[1]` through the synchronized frontend.

## 4. Command Classes

`tt_event_decode.sv` always projects the raw pin payload into all `tt_cmd_t` fields. The active meaning depends on `cmd.kind = ui_in[7:6]`.

### `CMD_CSR = 2'b00`

Writes one 8-bit CSR value.

Encoding:

- `ui_in[5:2] = csr_addr`
- `ui_in[1:0] = data[1:0]`
- `uio_in[7:2] = data[7:2]`

Reconstructed byte:

- `cmd.data = {uio_in[7:2], ui_in[1:0]}`

### `CMD_WEIGHT = 2'b01`

Writes one host-supplied ternary weight.

Encoding:

- `ui_in[5:2] = synapse_id`
- `ui_in[1:0] = weight_code`

Weight codes:

- `2'b00` => `0`
- `2'b01` => `+1`
- `2'b11` => `-1`
- `2'b10` => treated as `0`

### `CMD_UCODE = 2'b10`

Streams one microcode byte into the 16x16 microcode store.

Encoding:

- `ui_in[1:0] = data[1:0]`
- `uio_in[7:2] = data[7:2]`

The destination byte address comes from `ucode_ptr_r`. After acceptance:

- `ucode_prog_we` pulses for one cycle
- `ucode_prog_addr = ucode_ptr_r`
- `ucode_prog_data = cmd.data`
- `ucode_ptr_r` auto-increments

### `CMD_EVENT = 2'b11`

Queues one inbound event in the 2-entry FIFO.

Encoding:

- `ui_in[5:2] = sid`
- `ui_in[1:0] = tag`
- `uio_in[7:2] = event_time`

Queued event payload:

- `sid[3:0]`
- `tag[1:0]`
- `event_time[5:0]`

## 5. `cmd_ready` Behavior

The neuron core computes readiness from the decoded command class.

### Non-event commands

`CMD_CSR`, `CMD_WEIGHT`, and `CMD_UCODE` are accepted whenever:

- `ena = 1`
- `rst_n = 1`
- no event is currently in flight (`busy_r = 0`)

They do not depend on FIFO occupancy or a held output beat, but they are intentionally blocked while the core is mid-event so an in-flight event sees a stable program image and weight configuration.

### Event commands

`CMD_EVENT` is accepted only when:

- `ena = 1`
- `rst_n = 1`
- no event is currently in flight (`busy_r = 0`)
- no output beat is currently held
- the registered FIFO level is not `2`

The live implementation uses a state-only fullness check (`fifo_level != 2`) to avoid a combinational loop through FIFO ready/pop logic, so a full FIFO will not accept a same-cycle replacement push.

## 6. CSR Map

The core uses a compact wrapper-owned CSR bank.

### `0x0` `CSR_CTRL`

Pulse bits:

- `bit0`: soft runtime reset
- `bit1`: clear held output beat
- `bit2`: clear event FIFO

### `0x1` `CSR_UCODE_PTR`

- `cmd.data[4:0]` sets the byte pointer used by `CMD_UCODE`

### `0x2` `CSR_UCODE_LEN`

- `cmd.data[3:0]` sets the last active microcode step index
- `0` means one active instruction
- `15` means sixteen active instructions

### `0x3` `CSR_VEC_BASE_01`

- `cmd.data[3:0]` => vector base for `tag 0`
- `cmd.data[7:4]` => vector base for `tag 1`

### `0x4` `CSR_VEC_BASE_23`

- `cmd.data[3:0]` => vector base for `tag 2`
- `cmd.data[7:4]` => vector base for `tag 3`

### `0x5` `CSR_INIT_VI`

- `cmd.data[3:0]` => reset/init value for `R0 = V`
- `cmd.data[7:4]` => reset/init value for `R1 = I`

### `0x6` `CSR_INIT_TR`

- `cmd.data[3:0]` => reset/init value for `R2 = TH`
- `cmd.data[7:4]` => reset/init value for `R3 = R`

### `0x7` `CSR_INIT_T01`

- `cmd.data[3:0]` => reset/init value for `R4 = T0`
- `cmd.data[7:4]` => reset/init value for `R5 = T1`

### `0x8` `CSR_INIT_WAUX`

- `cmd.data[3:0]` => reset/init value for `R6 = W`
- `cmd.data[7:4]` => reset/init value for `R7 = AUX`

This only changes the RF reset image for `W` and `AUX`.

It does not preload the persistent 16-entry synapse weight bank. Use `CMD_WEIGHT` for that.

## 7. FIFO Semantics

The ingress FIFO is two entries deep and stores only event commands.

Properties:

- in-order delivery
- simultaneous push and pop supported
- `level` is `0`, `1`, or `2`
- `out_valid` mirrors whether slot 0 is occupied
- `clear` empties both entries immediately on the next clock edge

The neuron core pops automatically whenever:

- `ena = 1`
- `rst_n = 1`
- `have_out_r = 0`
- `out_valid = 1`

There is no separate "run" command for service once an event has entered the FIFO.

## 8. Output Beat Encoding

`uo_out[7:0]` is generated by the `EMIT` micro-op and stored in `neuron_state`.

Layout:

- `uo_out[7] = 1` valid marker
- `uo_out[6:5] = emitted tag literal`
- `uo_out[4:1] = last_sid`
- `uo_out[0] = spike_flag`

Only the first `EMIT` encountered during one event service pass is kept.

## 9. Practical Programming Sequence

A typical host-side setup looks like this:

1. Program `CSR_UCODE_PTR` if you want to start writing microcode somewhere other than byte `0`.
2. Stream microcode bytes with `CMD_UCODE`.
3. Program `CSR_UCODE_LEN`.
4. Program `CSR_VEC_BASE_01` and `CSR_VEC_BASE_23`.
5. Program any desired initial RF values with the `CSR_INIT_*` registers.
6. Program weights with `CMD_WEIGHT`.
7. Send events with `CMD_EVENT`.

Because non-event commands are blocked while `busy_r = 1`, the clean operating model is:

- program while idle
- then enqueue events
- then optionally perform more programming only after the current event retires

For a complete worked example, including how to map several core instances into a fully connected layer, see `docs/layer_examples.md`.
