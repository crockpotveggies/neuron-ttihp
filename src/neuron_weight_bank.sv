`default_nettype none

module neuron_weight_bank (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire       direct_we,
    input  wire [3:0] direct_idx,
    input  wire [1:0] direct_code,
    input  wire       exec_we,
    input  wire [3:0] exec_idx,
    input  wire signed [3:0] exec_value,
    output wire [63:0] weight_flat
);
`ifdef FORMAL
    // Flatten the bank in formal builds to avoid expensive memory lowering.
    reg [63:0] weight_flat_r;
`else
    reg signed [3:0] weight_mem [0:15];
    genvar g;
`endif
    integer idx;

    function automatic signed [3:0] ternary_from_code;
        input [1:0] code;
        begin
            case (code)
                2'b01: ternary_from_code = 4'sd1;
                2'b11: ternary_from_code = -4'sd1;
                default: ternary_from_code = 4'sd0;
            endcase
        end
    endfunction

    function automatic signed [3:0] ternary_clamp;
        input signed [3:0] value;
        begin
            if (value > 0)
                ternary_clamp = 4'sd1;
            else if (value < 0)
                ternary_clamp = -4'sd1;
            else
                ternary_clamp = 4'sd0;
        end
    endfunction

`ifdef FORMAL
    assign weight_flat = weight_flat_r;
`else
    generate
        for (g = 0; g < 16; g = g + 1) begin : gen_weight_flat
            assign weight_flat[g*4 +: 4] = weight_mem[g];
        end
    endgenerate
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
`ifdef FORMAL
            weight_flat_r <= 64'h0;
`else
            for (idx = 0; idx < 16; idx = idx + 1)
                weight_mem[idx] <= 4'sd0;
`endif
        end else if (!ena) begin
`ifdef FORMAL
            weight_flat_r <= 64'h0;
`else
            for (idx = 0; idx < 16; idx = idx + 1)
                weight_mem[idx] <= 4'sd0;
`endif
        end else begin
`ifdef FORMAL
            if (direct_we)
                weight_flat_r[{direct_idx, 2'b00} +: 4] <= ternary_clamp(ternary_from_code(direct_code));

            // Executor writes come last so the retiring event wins if both paths target the same entry.
            if (exec_we)
                weight_flat_r[{exec_idx, 2'b00} +: 4] <= ternary_clamp(exec_value);
`else
            if (direct_we)
                weight_mem[direct_idx] <= ternary_clamp(ternary_from_code(direct_code));

            // Executor writes come last so the retiring event wins if both paths target the same entry.
            if (exec_we)
                weight_mem[exec_idx] <= ternary_clamp(exec_value);
`endif
        end
    end
endmodule

`default_nettype wire
