`default_nettype none

module neuron_csr (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cmd_accept,
    input  wire       is_cmd_csr,
    input  wire       is_cmd_ucode,
    input  wire [3:0] cmd_addr,
    input  wire [7:0] cmd_data,
    output wire       soft_reset_cmd,
    output wire       clear_out_cmd,
    output wire       clear_fifo_cmd,
    output reg        ucode_prog_we,
    output reg  [4:0] ucode_prog_addr,
    output reg  [7:0] ucode_prog_data,
    output reg  [4:0] ucode_ptr_r,
    output reg  [3:0] ucode_len_r,
    output reg  [3:0] vector_base0_r,
    output reg  [3:0] vector_base1_r,
    output reg  [3:0] vector_base2_r,
    output reg  [3:0] vector_base3_r,
    output reg  [31:0] init_rf_flat
);
    localparam [3:0] CSR_CTRL        = 4'h0;
    localparam [3:0] CSR_UCODE_PTR   = 4'h1;
    localparam [3:0] CSR_UCODE_LEN   = 4'h2;
    localparam [3:0] CSR_VEC_BASE_01 = 4'h3;
    localparam [3:0] CSR_VEC_BASE_23 = 4'h4;
    localparam [3:0] CSR_INIT_VI     = 4'h5;
    localparam [3:0] CSR_INIT_TR     = 4'h6;
    localparam [3:0] CSR_INIT_T01    = 4'h7;
    localparam [3:0] CSR_INIT_WAUX   = 4'h8;

    // CSR_CTRL is decoded as one-cycle command pulses rather than latched mode bits.
    assign soft_reset_cmd = cmd_accept && is_cmd_csr && (cmd_addr == CSR_CTRL) && cmd_data[0];
    assign clear_out_cmd = cmd_accept && is_cmd_csr && (cmd_addr == CSR_CTRL) && cmd_data[1];
    assign clear_fifo_cmd = cmd_accept && is_cmd_csr && (cmd_addr == CSR_CTRL) && cmd_data[2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ucode_prog_we <= 1'b0;
            ucode_prog_addr <= 5'd0;
            ucode_prog_data <= 8'h00;
            ucode_ptr_r <= 5'd0;
            ucode_len_r <= 4'd0;
            vector_base0_r <= 4'd0;
            vector_base1_r <= 4'd0;
            vector_base2_r <= 4'd0;
            vector_base3_r <= 4'd0;
            init_rf_flat <= 32'h0000_0700;
        end else begin
            ucode_prog_we <= 1'b0;

            if (cmd_accept && is_cmd_csr) begin
                case (cmd_addr)
                    CSR_UCODE_PTR: ucode_ptr_r <= cmd_data[4:0];
                    CSR_UCODE_LEN: ucode_len_r <= cmd_data[3:0];

                    CSR_VEC_BASE_01: begin
                        vector_base0_r <= cmd_data[3:0];
                        vector_base1_r <= cmd_data[7:4];
                    end

                    CSR_VEC_BASE_23: begin
                        vector_base2_r <= cmd_data[3:0];
                        vector_base3_r <= cmd_data[7:4];
                    end

                    CSR_INIT_VI: begin
                        init_rf_flat[3:0] <= cmd_data[3:0];
                        init_rf_flat[7:4] <= cmd_data[7:4];
                    end

                    CSR_INIT_TR: begin
                        init_rf_flat[11:8] <= cmd_data[3:0];
                        init_rf_flat[15:12] <= cmd_data[7:4];
                    end

                    CSR_INIT_T01: begin
                        init_rf_flat[19:16] <= cmd_data[3:0];
                        init_rf_flat[23:20] <= cmd_data[7:4];
                    end

                    CSR_INIT_WAUX: begin
                        init_rf_flat[27:24] <= cmd_data[3:0];
                        init_rf_flat[31:28] <= cmd_data[7:4];
                    end

                    default: begin
                    end
                endcase
            end

            if (cmd_accept && is_cmd_ucode) begin
                // CMD_UCODE streams one byte at a time and auto-increments the byte pointer.
                ucode_prog_we <= 1'b1;
                ucode_prog_addr <= ucode_ptr_r;
                ucode_prog_data <= cmd_data;
                ucode_ptr_r <= ucode_ptr_r + 5'd1;
            end
        end
    end
endmodule

`default_nettype wire
