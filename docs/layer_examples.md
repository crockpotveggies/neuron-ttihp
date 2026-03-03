# Layer Programming Examples

This document answers the practical question:

How do you use the current 12-op programmable neuron ISA to build an actual layer?

The short answer is:

- the ISA programs one neuron's local event-update rule
- a layer is built outside the ISA by instantiating multiple neuron cores
- each core gets the same microcode program
- each core gets its own local weight row and threshold
- presynaptic events are routed or broadcast to every destination core that should see them

## What The ISA Actually Programs

One [neuron.sv](/Users/justin/Projects/coldfoot_soc/hw/ip/neuron/src/neuron.sv) instance is one programmable neuron core.

That core owns:

- one 8-register 4-bit state file
- one local 16-entry ternary weight bank
- one local 16-word microcode store
- one local 2-entry event FIFO

The ISA only defines what that one core does when it services an event.

It does not define:

- how many neurons exist in a layer
- which upstream sources feed which destination neurons
- fanout policy
- any global scheduler

Those are layer-level concerns in the surrounding fabric or host software.

## Fully Connected Layer Mapping

Assume a 3-input by 4-output fully connected layer:

- inputs: `x0`, `x1`, `x2`
- outputs: `y0`, `y1`, `y2`, `y3`

Represent it as four separate neuron-core instances:

- `N0` computes `y0`
- `N1` computes `y1`
- `N2` computes `y2`
- `N3` computes `y3`

Each core uses the same local `sid` convention:

- `sid = 0` means the event came from `x0`
- `sid = 1` means the event came from `x1`
- `sid = 2` means the event came from `x2`

Example ternary weight matrix:

| Output core | `w[x0]` | `w[x1]` | `w[x2]` |
|---|---:|---:|---:|
| `N0` | `+1` | `0` | `+1` |
| `N1` | `+1` | `-1` | `0` |
| `N2` | `0` | `+1` | `+1` |
| `N3` | `-1` | `+1` | `+1` |

Only `sid 0..2` are used; the remaining entries can stay at zero.

## A Practical Program For The Current RTL

The safest practical program in the current RTL is an integrate-and-report sequence:

1. receive the event metadata
2. read and accumulate the selected weight into `I`
3. integrate `I` into `V`
4. clear `I`
5. compute `spike_flag`
6. apply a spike-conditional reset
7. emit a report beat

This works well because `RESET` is now conditional on `spike_flag`, so the common "spike then reset" flow is expressible without a branch.

### Example microprogram

Register aliases:

- `R0 = V`
- `R1 = I`
- `R2 = TH`

Program at PC `0`:

| PC | Assembly intent | Meaning |
|---|---|---|
| `0` | `RECV` | capture `sid`, `tag`, `event_time` |
| `1` | `ACCUM_W` | `W = weight[last_sid]`, `I = sat(I + W)` |
| `2` | `INTEG` | `V = sat(V + I)` |
| `3` | `LDI I, 0` | clear accumulator |
| `4` | `SPIKE_IF_GE` | `spike_flag = (V >= TH)` |
| `5` | `RESET soft` | if `spike_flag`, `V = sat(V - TH)` |
| `6` | `EMIT tag=0` | emit `{1, tag, last_sid, spike_flag}` |

This produces one report beat per serviced event. Downstream logic should treat `uo_out[0]` as the true spike indicator.

## Exact Instruction Words

The current instruction format is:

- `op = word[15:11]`
- `rd = word[10:8]`
- `ra = word[7:5]`
- `rb = word[4:2]`
- `k = word[2:0]`

For the program above:

| PC | Instruction | 16-bit word | Low byte | High byte |
|---|---|---:|---:|---:|
| `0` | `RECV` | `16'h0800` | `8'h00` | `8'h08` |
| `1` | `ACCUM_W` | `16'h1000` | `8'h00` | `8'h10` |
| `2` | `INTEG` | `16'h2000` | `8'h00` | `8'h20` |
| `3` | `LDI I, 0` | `16'h0100` | `8'h00` | `8'h01` |
| `4` | `SPIKE_IF_GE` | `16'h2800` | `8'h00` | `8'h28` |
| `5` | `RESET mode=1` | `16'h3001` | `8'h01` | `8'h30` |
| `6` | `EMIT tag=0` | `16'h4000` | `8'h00` | `8'h40` |

Program the byte stream in this order:

```text
00 08 00 10 00 20 00 01 00 28 01 30 00 40
```

Then set:

- `CSR_UCODE_PTR = 0`
- `CSR_UCODE_LEN = 6`
- `CSR_VEC_BASE_01 = 0`
- `CSR_VEC_BASE_23 = 0`

## Per-Core Initialization

Assume:

- threshold `TH = +2`
- initial `V = 0`
- initial `I = 0`
- all traces and refractory state at `0`

Program:

- `CSR_INIT_VI = 8'h00`
- `CSR_INIT_TR = 8'h02`
- `CSR_INIT_T01 = 8'h00`
- `CSR_INIT_WAUX = 8'h00`

Important:

- `CSR_INIT_*` updates the reset image, not the live RF state
- `CSR_INIT_WAUX` only presets `W` and `AUX` in that reset image
- `CSR_INIT_WAUX` does not preload the persistent weight bank

To reload the live state from the programmed reset image:

- `CSR_CTRL = 8'h01`

## Loading The Fully Connected Weights

Program each output core's weight row separately with `CMD_WEIGHT`.

Example:

### `N0`

- `sid 0` -> `+1`
- `sid 1` -> `0`
- `sid 2` -> `+1`

### `N1`

- `sid 0` -> `+1`
- `sid 1` -> `-1`
- `sid 2` -> `0`

### `N2`

- `sid 0` -> `0`
- `sid 1` -> `+1`
- `sid 2` -> `+1`

### `N3`

- `sid 0` -> `-1`
- `sid 1` -> `+1`
- `sid 2` -> `+1`

## Host-Side Programming Flow

For each core:

1. Write `CSR_UCODE_PTR = 0`
2. Stream the 14 program bytes with `CMD_UCODE`
3. Write `CSR_UCODE_LEN = 6`
4. Write `CSR_VEC_BASE_01 = 0`, `CSR_VEC_BASE_23 = 0`
5. Write the `CSR_INIT_*` values
6. Issue `CSR_CTRL = 1` to reload live state from the init image
7. Write the local weight row with `CMD_WEIGHT`

In pseudocode:

```python
program = [0x00, 0x08, 0x00, 0x10, 0x00, 0x20, 0x00, 0x01,
           0x00, 0x28, 0x01, 0x30, 0x00, 0x40]

for core in [N0, N1, N2, N3]:
    write_csr(core, 0x1, 0x00)
    for byte in program:
        write_ucode_byte(core, byte)
    write_csr(core, 0x2, 0x06)
    write_csr(core, 0x3, 0x00)
    write_csr(core, 0x4, 0x00)
    write_csr(core, 0x5, 0x00)
    write_csr(core, 0x6, 0x02)
    write_csr(core, 0x7, 0x00)
    write_csr(core, 0x8, 0x00)
    write_csr(core, 0x0, 0x01)

load_weights(N0, [+1,  0, +1])
load_weights(N1, [+1, -1,  0])
load_weights(N2, [ 0, +1, +1])
load_weights(N3, [-1, +1, +1])
```

## Driving Input Spikes

Suppose the input side emits:

- `x0` at time `1`
- `x2` at time `2`

For a fully connected layer, send those events to every output core:

1. `CMD_EVENT(sid=0, tag=0, event_time=1)` to `N0..N3`
2. `CMD_EVENT(sid=2, tag=0, event_time=2)` to `N0..N3`

That is what "fully connected" means here: each postsynaptic core sees every presynaptic event and interprets it through its own local weight row.

## Interpreting Outputs

The output beat format is:

- `bit 7`: always `1`
- `bits 6:5`: literal tag from `EMIT`
- `bits 4:1`: `last_sid`
- `bit 0`: `spike_flag`

So:

- `bit 0 = 1` means the neuron crossed threshold on that event
- `bit 0 = 0` means it was only a report beat

## Worked State Example

Take `N0` with:

- `w[x0] = +1`
- `w[x1] = 0`
- `w[x2] = +1`
- `TH = +2`
- initial `V = 0`

### Event 1: `x0`

1. `RECV` captures `last_sid = 0`
2. `ACCUM_W` makes `I = +1`
3. `INTEG` makes `V = +1`
4. `LDI I,0` clears `I`
5. `SPIKE_IF_GE` sets `spike_flag = 0`
6. `RESET soft` does nothing because `spike_flag = 0`
7. `EMIT` reports `spike_flag = 0`

### Event 2: `x2`

1. `RECV` captures `last_sid = 2`
2. `ACCUM_W` makes `I = +1`
3. `INTEG` makes `V = +2`
4. `LDI I,0` clears `I`
5. `SPIKE_IF_GE` sets `spike_flag = 1`
6. `RESET soft` applies and returns `V` to `V - TH = 0`
7. `EMIT` reports `spike_flag = 1`

That second report beat is the logical spike from `N0`.

## Practical Notes

- Keep the output consumer ready. The core will not start a new event while an output beat is still held.
- The 2-entry FIFO allows short bursts, but it is intentionally small.
- The same program can be reused across a whole layer; only weights, thresholds, and routing change.
- The single-op microsequencer increases per-event latency, but the programming model stays the same.

## Summary

To "program a layer" in this design:

- program one straight-line neuron update rule
- replicate that rule across many cores
- load one weight row per output neuron
- route each presynaptic event to every destination core that should see it

The ISA is local neuron behavior. The layer is the collection of instances plus the event-routing pattern around them.
