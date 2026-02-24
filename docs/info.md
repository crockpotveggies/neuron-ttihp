# Neuron Tile Specification

**Module name:** `neuron`  
**Purpose:** Single-neuron, event-driven neuromorphic tile with selectable neuron modes, programmable synapses, activation streaming, and STDP-lite on-chip learning.  
**Intended use:** TinyTapeout shuttle projects and USB-serial demo boards (via RP2040 bridge driving IO pins).

---

## 1. Top-Level Interface

### 1.1 Ports (TinyTapeout standard)
```verilog
module neuron (
`ifdef USE_POWER_PINS
    input  wire VGND,
    input  wire VPWR,
`endif
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
```

### 1.2 Handshake and sideband mapping
The design uses a **TT-safe synchronous handshake** (all state updates on `posedge clk`) but is **event-driven at the interface**: state changes occur only when an input event is accepted.

- **Input event request:** `in_req = uio_in[0]`
- **Input event acknowledge:** `in_ack = uio_out[0]`
- **Output event request:** `out_req = uio_out[1]`
- **Output event acknowledge:** `out_ack = uio_in[1]`

- **Input payload (8-bit):** `in_data = ui_in[7:0]`
- **Output payload (8-bit):** `out_data = uo_out[7:0]`

- **Config sideband (only meaningful when config opcode is used):**
  - `cfg_arg = uio_in[7:4]` (4-bit)
  - `cfg_op  = uio_in[3:2]` (2-bit)

**Pins driven by the design:**
- `uio_oe[1:0] = 1` (outputs enabled for `in_ack` and `out_req`)
- `uio_oe[7:2] = 0` (inputs)
- `uio_out[7:2] = 0` (driven low)

---

## 2. Event Protocol (Input)

### 2.1 Input event format (`ui_in[7:0]`)
| Bit(s) | Name | Meaning |
|---|---|---|
| 7 | `is_tick` | `1` = tick (time step), `0` = spike/config event |
| 6 | `polarity` | Used only for **hashy weight** selection (addr 16..60). `0` selects table A, `1` selects table B |
| 5:0 | `addr` | 6-bit address / opcode |

### 2.2 Special addresses (when `is_tick=0`)
- `addr = 61` (`ADDR_RESET`): soft reset (clears neuron state and learning traces; **does not clear weights**)
- `addr = 62` (`ADDR_ARM`): arm first-spike timing (FST) timer (sets `fst_armed=1`, clears `fst_t`)
- `addr = 63` (`ADDR_CFG`): config opcode (uses `cfg_op/cfg_arg` on `uio_in`)

All other addresses (0..60) are treated as “spike events” into the neuron (behavior depends on `mode`).

---

## 3. Output Protocol

### 3.1 Output event format (`uo_out[7:0]`)
| Bit(s) | Name | Meaning |
|---|---|---|
| 7 | `valid` | Always `1` for emitted events |
| 6:4 | `type` | `TYPE_SPIKE=3'b000` spike event; `TYPE_ACT=3'b101` activation sample |
| 3:0 | `payload` | 4-bit payload (mode-specific) |

### 3.2 Output types
- **Spike output**: `{1, TYPE_SPIKE, payload}`
- **Activation sample** (streamed): `{1, TYPE_ACT, act4}`

Because the design uses a **single-entry output buffer**, it can emit **at most one output per accepted input event**.

---

## 4. Handshake Semantics

### 4.1 Input acceptance
An input event is accepted when `in_req && in_ack` is sampled high on a rising clock edge.

- External inputs are internally synchronized to `clk` (2-flop synchronizers on `ui_in` and `uio_in`).
- `in_ack = 1` iff `ena && rst_n && (output buffer empty) && (synchronized in_req is high) && (current in_req not yet accepted)`
- While `in_req` remains asserted, only one input event is accepted (host must deassert and reassert `in_req` for the next event).
- If an output is pending (`out_req=1`), then `in_ack=0` (backpressure)

### 4.2 Output consumption
An output event is consumed when `out_req && out_ack` is sampled high on a rising clock edge. The output buffer clears on the next cycle.

### 4.3 Recommended driving rules (host / RP2040 firmware)
- Hold `ui_in` stable while asserting `in_req` until `in_ack==1` is observed.
- Only assert `out_ack` when `out_req==1` to consume an output.

---

## 5. Synapses and Weights

### 5.1 Programmable synapse window
Addresses `0..15` (`addr[5:4]==00`) are **programmable** using a 16-entry table:

- `wtab[0..15]`: **2-bit unsigned weight** per synapse (`0..3`)
- Storage: 32 bits total

When `addr` is in `0..15`, the effective weight is:
- `w_eff = wtab[addr[3:0]]`

### 5.2 Hashy weights for addresses 16..60
For `addr` outside `0..15`, a lightweight combinational “hash” produces `w_hash` in `0..3`, with `polarity` selecting between two hash tables.

An optional bias is applied to reduce zeros:
- if `w_hash==0` then `w_hash_eff=1`, else `w_hash_eff=w_hash`

Effective weight for non-programmable addresses:
- `w_eff = w_hash_eff`

---

## 6. Configuration Interface (addr=63)

When `is_tick=0` and `addr=63`, the input event is treated as a config transaction.

### 6.1 Config fields
- `cfg_op  = uio_in[3:2]` (2-bit opcode)
- `cfg_arg = uio_in[7:4]` (4-bit argument)

### 6.2 Config opcodes
| `cfg_op` | Name | Description |
|---|---|---|
| `00` | `SET_WIDX` | `pending_widx <= cfg_arg` (select weight table index 0..15) |
| `01` | `WRITE_W`  | `wtab[pending_widx] <= cfg_arg[1:0]` |
| `10` | `SET_MODE` | Sets mode + streaming + learning enable (see below) |
| `11` | Reserved | No action (available for future expansion) |

### 6.3 SET_MODE encoding (`cfg_op=10`)
`cfg_arg` bits:
- `cfg_arg[1:0] = mode`
- `cfg_arg[2]   = stream_act`
- `cfg_arg[3]   = learn_en`

Defaults after reset:
- `mode = 0` (LIF)
- `stream_act = 1` (on)
- `learn_en = 0` (off)

---

## 7. Neuron Modes and Dynamics

The tile behaves as a **single neuron** whose update rules depend on `mode`.

### Mode 0: LIF (Leaky Integrate-and-Fire)
- State: `lif_V` (8-bit)
- Parameters:
  - Threshold `LIF_THR = 32`
  - Leak shift `LIF_LEAK_SHIFT = 3` (shift-leak)

**On spike event (is_tick=0, addr 0..60 excluding special):**
- `lif_V_next = sat(lif_V + w_eff)`
- If `lif_V_next >= LIF_THR`:
  - emit `TYPE_SPIKE` (payload `0`)
  - reset `lif_V = 0`
  - set `post_trace = 1` (learning)
  - if `learn_en=1`, start serial LTP scan (`learn_pending=1`)

**On tick event (is_tick=1):**
- `lif_V = lif_V - (lif_V >> LIF_LEAK_SHIFT)`
- if `stream_act=1`, emit `TYPE_ACT` with `lif_V[3:0]` (if no spike output emitted on that event)

### Mode 1: Temporal Differencing (TD)
- State: `td_curr`, `td_prev`, `td_last_diff`
- Parameter: `TD_THR = 4`

**On spike event:**
- `td_curr = sat(td_curr + w_eff)` (8-bit saturating)

**On tick event:**
- `diff = max(td_curr - td_prev, 0)` (floored at zero)
- `td_last_diff = diff`
- `td_prev = td_curr; td_curr = 0`
- If `diff >= TD_THR`: emit `TYPE_SPIKE` with payload `diff[3:0]`
- Else if `stream_act=1`: emit `TYPE_ACT` with payload `diff[3:0]`

### Mode 2: First-Spike Timing (FST)
- State: `fst_armed`, `fst_t`, `fst_last_t`

**Arm (is_tick=0, addr=62):**
- `fst_armed = 1; fst_t = 0`

**On tick event:**
- if `fst_armed`: `fst_t++` (saturating at 255)
- if `stream_act=1`: emit `TYPE_ACT` with payload:
  - if armed: `fst_t[3:0]`
  - else: `fst_last_t[3:0]`

**On spike event:**
- if `fst_armed`:
  - capture `fst_last_t = fst_t`
  - disarm `fst_armed=0`
  - emit `TYPE_SPIKE` with payload `fst_t[3:0]`

### Mode 3: Temporal Convolution (CONV)
A minimal temporal “spiking conv” filter on a 4-tick activity window.

- State: `conv_shift[3:0]`, `spike_seen_this_tick`, `conv_last_sum`
- Kernel: `K0=1, K1=2, K2=1, K3=0`
- Threshold: `CONV_THR=3`

**On spike event:**
- sets `spike_seen_this_tick = 1`

**On tick event:**
- `conv_shift = {conv_shift[2:0], spike_seen_this_tick}`
- compute `sum_next = Σ (conv_shift[i] ? Ki : 0)`
- `conv_last_sum = sum_next`
- clear `spike_seen_this_tick = 0`
- If `sum_next >= CONV_THR`: emit `TYPE_SPIKE` with payload `{0,sum_next}` (0..7)
- Else if `stream_act=1`: emit `TYPE_ACT` with payload `{0,sum_next}`

---

## 8. STDP-lite On-Chip Learning

Learning is designed to be **TinyTapeout-practical**: low area, low fanout, no per-synapse timers.

### 8.1 Learning enable
- `learn_en` is controlled by config: `SET_MODE` (`cfg_arg[3]`)

### 8.2 Learning state
- `pre_trace[15:0]`: 1-bit “recent pre-spike” flag per programmable synapse (0..15)
- `post_trace`: 1-bit “recent post-spike” flag
- `learn_pending`: serial LTP scan active
- `learn_ptr[3:0]`: synapse index being processed (0..15)

### 8.3 Pre-spike behavior (trace + LTD)
On any **spike event** (in any mode), if `addr` is programmable (`0..15`):
- set `pre_trace[addr] = 1`
- if `learn_en && post_trace` then apply **LTD**:
  - `wtab[addr] = max(wtab[addr]-1, 0)`

### 8.4 Post-spike behavior (post_trace + LTP trigger)
When the neuron emits a **post spike** (`TYPE_SPIKE`), it sets:
- `post_trace = 1`

Additionally, **in LIF mode only**, if `learn_en=1`:
- starts the serial **LTP scan**:
  - `learn_pending = 1`
  - `learn_ptr = 0`

### 8.5 Serial LTP scan (one update per accepted input event)
While `learn_pending=1`, on each accepted input event:
- if `pre_trace[learn_ptr] == 1`:
  - `wtab[learn_ptr] = min(wtab[learn_ptr]+1, 3)`
  - `pre_trace[learn_ptr] = 0`
- advance `learn_ptr`
- when `learn_ptr==15`, clear `learn_pending` and reset `learn_ptr=0`

### 8.6 Bounding the LTD window
On any **tick event** (`is_tick=1`):
- `post_trace` clears (`post_trace=0`)

This bounds how long a post-spike can depress subsequent pre-spikes.

---

## 9. Activation Streaming (UI-friendly)

If `stream_act=1`, then on every **tick event** the tile attempts to emit an activation sample:
- `TYPE_ACT` with a 4-bit payload `act4`

Mode-specific `act4`:
- LIF: `lif_V[3:0]`
- TD: `td_last_diff[3:0]` (or current tick diff)
- FST: `fst_t[3:0]` if armed else `fst_last_t[3:0]`
- CONV: `{0, conv_last_sum}`

**Note:** Only one output can be buffered at a time. If the output buffer is busy, the activation sample for that tick may be skipped due to backpressure.

---

## 10. Reset Behavior

### 10.1 Hardware reset (`rst_n=0`)
Clears:
- output buffer
- all neuron state (membrane/counters/traces)
- weight table (`wtab`) is reset to zero

### 10.2 Soft reset event (is_tick=0, addr=61)
Clears:
- neuron state and learning traces
- **does not clear weights** (`wtab` unchanged)

---

## 11. Demo/Host Integration Notes (USB-Serial)

On TinyTapeout demo boards, USB-C serial connects to an onboard microcontroller (e.g., RP2040) which then drives the ASIC IO pins:

- Host UI sends “spike” and “tick” events over serial to RP2040 firmware.
- Firmware toggles `in_req`, places data on `ui_in`, and reads `uo_out` when `out_req` asserts.

This design’s activation streaming makes it straightforward to plot or visualize activity in real-time:
- Plot `TYPE_ACT` payload as a bar graph/trace per tick.
- Treat `TYPE_SPIKE` as event markers.

---

## 12. Quick Reference

### Input: send a tick
- `ui_in = 8'b1xxxxxxx` (recommended `0x80`)
- assert `in_req` until `in_ack=1`

### Input: send a spike to synapse i (0..15)
- `ui_in = {is_tick=0, polarity=?, addr=i}`

### Config: set mode + streaming + learning
- send config event `ui_in = {0,0,63}`
- set `cfg_op=2'b10`
- set `cfg_arg = {learn_en, stream_act, mode[1:0]}`

### Output: decode event
- `uo_out[7]` valid
- `uo_out[6:4]` type (SPIKE=0, ACT=5)
- `uo_out[3:0]` payload
