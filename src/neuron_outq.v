`default_nettype none

module neuron_outq (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire       out_fire,
    input  wire       emit_valid,
    input  wire [7:0] emit_data,
    output reg        have_out,
    output reg  [7:0] out_data_r
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            have_out   <= 1'b0;
            out_data_r <= 8'h00;
        end else if (!ena) begin
            have_out   <= 1'b0;
            out_data_r <= 8'h00;
        end else begin
            if (out_fire) begin
                have_out   <= 1'b0;
                out_data_r <= 8'h00;
            end

            if (emit_valid && !have_out) begin
                have_out   <= 1'b1;
                out_data_r <= emit_data;
            end
        end
    end
endmodule

`default_nettype wire
