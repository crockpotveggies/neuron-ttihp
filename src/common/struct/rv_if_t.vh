`ifndef RV_IF_T_VH
`define RV_IF_T_VH

typedef struct packed {
  logic [1:0] kind;
  logic [3:0] addr;
  logic [7:0] data;
  logic [3:0] sid;
  logic [1:0] tag;
  logic [5:0] event_time;
  logic [1:0] weight_code;
} tt_cmd_t;

typedef struct packed {
  logic [3:0] sid;
  logic [1:0] tag;
  logic [5:0] event_time;
} neuron_event_t;

typedef struct packed {
  logic [1:0] tag;
  logic [3:0] sid;
  logic       spike;
} neuron_emit_t;

typedef struct packed {
  logic [4:0] op;
  logic [2:0] rd;
  logic [2:0] ra;
  logic [2:0] rb;
  logic [2:0] k;
} micro_instr_t;

// Front-end control bundle for TinyTapeout boundary synchronization.
typedef struct packed {
  logic out_valid;
  logic in_ready;
  logic in_fire;
} io_frontend_ctrl_t;

`endif // RV_IF_T_VH
