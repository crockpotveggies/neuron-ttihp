`default_nettype none

module neuron_mode_lif (
    input  wire [7:0] lif_V,
    input  wire [1:0] w_eff,
    input  wire       active_event,
    input  wire       is_tick,
    input  wire       stream_act,
    input  wire       learn_en,
    input  wire       have_out,
    output wire [7:0] lif_V_next,
    output wire       emit_valid,
    output wire [7:0] emit_data,
    output wire       post_spike_pulse,
    output wire       learn_start_pulse
);
    `include "neuron_defs.vh"
    `include "neuron_math.vh"

    localparam [7:0] LIF_THR = 8'd32;
    localparam [2:0] LIF_LEAK_SHIFT = 3'd3;

    wire [7:0] lif_v_add = sat_add8_2b(lif_V, w_eff);
    wire       lif_fire  = (lif_v_add >= LIF_THR);

    assign lif_V_next = active_event
        ? (is_tick ? leak8(lif_V, LIF_LEAK_SHIFT) : (lif_fire ? 8'd0 : lif_v_add))
        : lif_V;

    wire emit_spike = active_event && !is_tick && lif_fire && !have_out;
    wire emit_act   = active_event &&  is_tick && stream_act && !have_out;

    assign emit_valid = emit_spike || emit_act;
    assign emit_data  = emit_spike
        ? {1'b1, `NEURON_TYPE_SPIKE, 4'h0}
        : {1'b1, `NEURON_TYPE_ACT, lif_V[3:0]};

    assign post_spike_pulse  = emit_spike;
    assign learn_start_pulse = emit_spike && learn_en;
endmodule

`default_nettype wire
