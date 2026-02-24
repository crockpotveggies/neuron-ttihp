`default_nettype none

module neuron_mode_conv (
    input  wire [3:0] conv_shift,
    input  wire       spike_seen_this_tick,
    input  wire [2:0] conv_last_sum,
    input  wire       active_event,
    input  wire       is_tick,
    input  wire       stream_act,
    input  wire       have_out,
    output wire [3:0] conv_shift_next,
    output wire       spike_seen_this_tick_next,
    output wire [2:0] conv_last_sum_next,
    output wire       emit_valid,
    output wire [7:0] emit_data,
    output wire       post_spike_pulse,
    output wire       learn_start_pulse
);
    `include "neuron_defs.vh"

    localparam [2:0] CONV_THR = 3'd3;
    localparam [1:0] K0 = 2'd1;
    localparam [1:0] K1 = 2'd2;
    localparam [1:0] K2 = 2'd1;
    localparam [1:0] K3 = 2'd0;

    wire [3:0] conv_next_shift = {conv_shift[2:0], spike_seen_this_tick};
    wire [2:0] conv_sum_next =
        (conv_next_shift[0] ? K0 : 0) +
        (conv_next_shift[1] ? K1 : 0) +
        (conv_next_shift[2] ? K2 : 0) +
        (conv_next_shift[3] ? K3 : 0);

    wire conv_fire = (conv_sum_next >= CONV_THR);

    assign conv_shift_next = (active_event && is_tick) ? conv_next_shift : conv_shift;
    assign conv_last_sum_next = (active_event && is_tick) ? conv_sum_next : conv_last_sum;
    assign spike_seen_this_tick_next = active_event
        ? (is_tick ? 1'b0 : 1'b1)
        : spike_seen_this_tick;

    wire emit_spike = active_event && is_tick && conv_fire && !have_out;
    wire emit_act   = active_event && is_tick && !conv_fire && stream_act && !have_out;

    assign emit_valid = emit_spike || emit_act;
    assign emit_data = emit_spike
        ? {1'b1, `NEURON_TYPE_SPIKE, {1'b0, conv_sum_next}}
        : {1'b1, `NEURON_TYPE_ACT, {1'b0, conv_sum_next}};

    assign post_spike_pulse  = emit_spike;
    assign learn_start_pulse = 1'b0;
endmodule

`default_nettype wire
