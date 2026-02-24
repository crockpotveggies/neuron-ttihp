`default_nettype none

module neuron_synapse_bank (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire [5:0] addr,
    input  wire       polarity,
    input  wire       cfg_set_widx_fire,
    input  wire       cfg_write_w_fire,
    input  wire [3:0] cfg_arg,
    input  wire       ltp_we,
    input  wire [3:0] ltp_idx,
    input  wire [1:0] ltp_wdata,
    input  wire       ltd_we,
    input  wire [3:0] ltd_idx,
    input  wire [1:0] ltd_wdata,
    output reg  [31:0] wtab,
    output reg  [3:0]  pending_widx,
    output wire        is_prog_addr,
    output wire [1:0]  w_eff
);
    wire [1:0] w_prog = wtab[{addr[3:0], 1'b0} +: 2];

    wire [1:0] w0 = {
        (addr[5] ^ addr[2] ^ addr[0]),
        (addr[4] ^ addr[1] ^ addr[0])
    };

    wire [1:0] w1 = {
        (addr[5] ^ addr[3] ^ addr[1]),
        (addr[4] ^ addr[2] ^ addr[1])
    };

    wire [1:0] w_hash = polarity ? w1 : w0;
    wire [1:0] w_hash_eff = (w_hash == 2'b00) ? 2'b01 : w_hash;

    assign is_prog_addr = (addr[5:4] == 2'b00);
    assign w_eff = is_prog_addr ? w_prog : w_hash_eff;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wtab         <= 32'h0000_0000;
            pending_widx <= 4'd0;
        end else if (ena) begin
            if (cfg_set_widx_fire)
                pending_widx <= cfg_arg;

            if (cfg_write_w_fire)
                wtab[{pending_widx, 1'b0} +: 2] <= cfg_arg[1:0];

            if (ltp_we)
                wtab[{ltp_idx, 1'b0} +: 2] <= ltp_wdata;

            if (ltd_we)
                wtab[{ltd_idx, 1'b0} +: 2] <= ltd_wdata;
        end
    end
endmodule

`default_nettype wire
