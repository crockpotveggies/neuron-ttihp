`default_nettype none

module neuron_state (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ena,
    input  wire [31:0] init_rf_flat,
    input  wire        soft_reset_cmd,
    input  wire        clear_out_cmd,
    input  wire        out_ready,
    input  wire        commit_event,
    input  wire [31:0] rf_next_flat,
    input  wire [3:0]  last_sid_next,
    input  wire [1:0]  last_tag_next,
    input  wire [5:0]  last_time_next,
    input  wire        cmp_ge_next,
    input  wire        cmp_eq_next,
    input  wire        spike_flag_next,
    input  wire        emit_pending_next,
    input  wire [7:0]  emit_data_next,
    output reg  [31:0] rf_state_flat,
    output reg  [3:0]  last_sid_r,
    output reg  [1:0]  last_tag_r,
    output reg  [5:0]  last_time_r,
    output reg         cmp_ge_r,
    output reg         cmp_eq_r,
    output reg         spike_flag_r,
    output reg         have_out_r,
    output reg  [7:0]  out_data_r
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_state_flat <= 32'h0000_0700;
            last_sid_r <= 4'd0;
            last_tag_r <= 2'd0;
            last_time_r <= 6'd0;
            cmp_ge_r <= 1'b0;
            cmp_eq_r <= 1'b0;
            spike_flag_r <= 1'b0;
            have_out_r <= 1'b0;
            out_data_r <= 8'h00;
        end else begin
            if (!ena) begin
                rf_state_flat <= init_rf_flat;
                last_sid_r <= 4'd0;
                last_tag_r <= 2'd0;
                last_time_r <= 6'd0;
                cmp_ge_r <= 1'b0;
                cmp_eq_r <= 1'b0;
                spike_flag_r <= 1'b0;
                have_out_r <= 1'b0;
                out_data_r <= 8'h00;
            end else begin
                // Output acknowledge and explicit clear drain the held beat independently of state commit.
                if (out_ready || clear_out_cmd) begin
                    have_out_r <= 1'b0;
                    out_data_r <= 8'h00;
                end

                if (soft_reset_cmd) begin
                    rf_state_flat <= init_rf_flat;
                    last_sid_r <= 4'd0;
                    last_tag_r <= 2'd0;
                    last_time_r <= 6'd0;
                    cmp_ge_r <= 1'b0;
                    cmp_eq_r <= 1'b0;
                    spike_flag_r <= 1'b0;
                end

                if (commit_event) begin
                    // The scheduler presents fully retired event state here, so commit is atomic.
                    rf_state_flat <= rf_next_flat;
                    last_sid_r <= last_sid_next;
                    last_tag_r <= last_tag_next;
                    last_time_r <= last_time_next;
                    cmp_ge_r <= cmp_ge_next;
                    cmp_eq_r <= cmp_eq_next;
                    spike_flag_r <= spike_flag_next;

                    if (emit_pending_next) begin
                        have_out_r <= 1'b1;
                        out_data_r <= emit_data_next;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
