`default_nettype none

module neuron_mode_td (
    input  wire [7:0] td_curr,
    input  wire [7:0] td_prev,
    input  wire [7:0] td_last_diff,
    input  wire [1:0] w_eff,
    input  wire       active_event,
    input  wire       is_tick,
    input  wire       stream_act,
    input  wire       have_out,
    output wire [7:0] td_curr_next,
    output wire [7:0] td_prev_next,
    output wire [7:0] td_last_diff_next,
    output wire       emit_valid,
    output wire [7:0] emit_data,
    output wire       post_spike_pulse,
    output wire       learn_start_pulse
);
    `include "neuron_defs.vh"
    `include "neuron_math.vh"

    localparam [7:0] TD_THR = 8'd4;

    wire [7:0] td_diff = (td_curr >= td_prev) ? (td_curr - td_prev) : 8'd0;
    wire       td_fire = (td_diff >= TD_THR);

    assign td_curr_next = active_event
        ? (is_tick ? 8'd0 : sat_add8_2b(td_curr, w_eff))
        : td_curr;

    assign td_prev_next = (active_event && is_tick) ? td_curr : td_prev;
    assign td_last_diff_next = (active_event && is_tick) ? td_diff : td_last_diff;

    wire emit_spike = active_event && is_tick && td_fire && !have_out;
    wire emit_act   = active_event && is_tick && !td_fire && stream_act && !have_out;

    assign emit_valid = emit_spike || emit_act;
    assign emit_data = emit_spike
        ? {1'b1, `NEURON_TYPE_SPIKE, td_diff[3:0]}
        : {1'b1, `NEURON_TYPE_ACT, td_diff[3:0]};

    assign post_spike_pulse  = emit_spike;
    assign learn_start_pulse = 1'b0;
endmodule

`default_nettype wire
