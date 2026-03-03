`default_nettype none

module neuron_ucode_store (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        prog_we,
    input  wire [4:0]  prog_addr,
    input  wire [7:0]  prog_data,
    output wire [255:0] ucode_flat
);
`ifdef FORMAL
    // Flatten the store in formal builds so Yosys does not spend time lowering memories.
    reg [255:0] ucode_flat_r;
`else
    reg [15:0] ucode_mem [0:15];
    genvar g;
`endif

`ifdef FORMAL
    assign ucode_flat = ucode_flat_r;
`else
    generate
        for (g = 0; g < 16; g = g + 1) begin : gen_ucode_flat
            assign ucode_flat[g*16 +: 16] = ucode_mem[g];
        end
    endgenerate
`endif

    integer idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
`ifdef FORMAL
            ucode_flat_r <= 256'h0;
`else
            for (idx = 0; idx < 16; idx = idx + 1)
                ucode_mem[idx] <= 16'h0000;
`endif
        end else if (prog_we) begin
`ifdef FORMAL
            // prog_addr[0] selects the low or high byte within the addressed 16-bit word.
            if (prog_addr[0])
                ucode_flat_r[{prog_addr[4:1], 4'b1000} +: 8] <= prog_data;
            else
                ucode_flat_r[{prog_addr[4:1], 4'b0000} +: 8] <= prog_data;
`else
            // prog_addr[0] selects the low or high byte within the addressed 16-bit word.
            if (prog_addr[0])
                ucode_mem[prog_addr[4:1]] <= {prog_data, ucode_mem[prog_addr[4:1]][7:0]};
            else
                ucode_mem[prog_addr[4:1]] <= {ucode_mem[prog_addr[4:1]][15:8], prog_data};
`endif
        end
    end
endmodule

`default_nettype wire
