`default_nettype none

module neuron_mode_select (
    input  wire [1:0] mode,
    input  wire       lif_emit_valid,
    input  wire [7:0] lif_emit_data,
    input  wire       lif_post_spike,
    input  wire       lif_learn_start,
    input  wire       td_emit_valid,
    input  wire [7:0] td_emit_data,
    input  wire       td_post_spike,
    input  wire       td_learn_start,
    input  wire       fst_emit_valid,
    input  wire [7:0] fst_emit_data,
    input  wire       fst_post_spike,
    input  wire       fst_learn_start,
    input  wire       conv_emit_valid,
    input  wire [7:0] conv_emit_data,
    input  wire       conv_post_spike,
    input  wire       conv_learn_start,
    output reg        emit_valid,
    output reg  [7:0] emit_data,
    output reg        post_spike_pulse,
    output reg        learn_start_pulse
);
    `include "neuron_defs.vh"

    always @* begin
        emit_valid = 1'b0;
        emit_data = 8'h00;
        post_spike_pulse = 1'b0;
        learn_start_pulse = 1'b0;

        case (mode)
            `NEURON_MODE_LIF: begin
                emit_valid = lif_emit_valid;
                emit_data = lif_emit_data;
                post_spike_pulse = lif_post_spike;
                learn_start_pulse = lif_learn_start;
            end
            `NEURON_MODE_TD: begin
                emit_valid = td_emit_valid;
                emit_data = td_emit_data;
                post_spike_pulse = td_post_spike;
                learn_start_pulse = td_learn_start;
            end
            `NEURON_MODE_FST: begin
                emit_valid = fst_emit_valid;
                emit_data = fst_emit_data;
                post_spike_pulse = fst_post_spike;
                learn_start_pulse = fst_learn_start;
            end
            default: begin
                emit_valid = conv_emit_valid;
                emit_data = conv_emit_data;
                post_spike_pulse = conv_post_spike;
                learn_start_pulse = conv_learn_start;
            end
        endcase
    end
endmodule

`default_nettype wire
