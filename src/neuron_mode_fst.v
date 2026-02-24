`default_nettype none

module neuron_mode_fst (
    input  wire       fst_armed,
    input  wire [7:0] fst_t,
    input  wire [7:0] fst_last_t,
    input  wire       active_event,
    input  wire       arm_event,
    input  wire       is_tick,
    input  wire       stream_act,
    input  wire       have_out,
    output wire       fst_armed_next,
    output wire [7:0] fst_t_next,
    output wire [7:0] fst_last_t_next,
    output wire       emit_valid,
    output wire [7:0] emit_data,
    output wire       post_spike_pulse,
    output wire       learn_start_pulse
);
    `include "neuron_defs.vh"

    wire [7:0] fst_t_inc = (fst_t != 8'hFF) ? (fst_t + 8'd1) : fst_t;

    assign fst_armed_next = arm_event
        ? 1'b1
        : (active_event && !is_tick && fst_armed) ? 1'b0 : fst_armed;

    assign fst_t_next = arm_event
        ? 8'd0
        : (active_event && is_tick && fst_armed) ? fst_t_inc : fst_t;

    assign fst_last_t_next = (active_event && !is_tick && fst_armed) ? fst_t : fst_last_t;

    wire emit_spike = active_event && !is_tick && fst_armed && !have_out;
    wire emit_act   = active_event &&  is_tick && stream_act && !have_out;

    assign emit_valid = emit_spike || emit_act;
    assign emit_data = emit_spike
        ? {1'b1, `NEURON_TYPE_SPIKE, fst_t[3:0]}
        : {1'b1, `NEURON_TYPE_ACT, (fst_armed ? fst_t_inc[3:0] : fst_last_t[3:0])};

    assign post_spike_pulse  = emit_spike;
    assign learn_start_pulse = 1'b0;
endmodule

`default_nettype wire
