`default_nettype none

module neuron_io_frontend (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire [7:0] ui_in,
    input  wire [7:0] uio_in,
    input  wire       have_out,
    output reg  [7:0] ui_in_sync,
    output reg  [7:0] uio_in_sync,
    output reg        in_req_seen,
    output wire       in_ack,
    output wire       out_req,
    output wire       in_fire,
    output wire       out_fire,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);
    reg [7:0] ui_in_meta;
    reg [7:0] uio_in_meta;

    wire in_req  = uio_in_sync[0];
    wire out_ack = uio_in_sync[1];

    assign out_req = have_out;
    assign in_ack  = (ena && rst_n && !have_out && in_req && !in_req_seen);
    assign in_fire = in_req & in_ack;
    assign out_fire = out_req & out_ack;

    assign uio_out = {6'b0, out_req, in_ack};
    assign uio_oe  = {6'b0, 1'b1,   1'b1};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ui_in_meta  <= 8'h00;
            ui_in_sync  <= 8'h00;
            uio_in_meta <= 8'h00;
            uio_in_sync <= 8'h00;
            in_req_seen <= 1'b0;
        end else begin
            ui_in_meta  <= ui_in;
            ui_in_sync  <= ui_in_meta;
            uio_in_meta <= uio_in;
            uio_in_sync <= uio_in_meta;

            if (!ena) begin
                if (!in_req)
                    in_req_seen <= 1'b0;
            end else begin
                if (!in_req)
                    in_req_seen <= 1'b0;
                else if (in_fire)
                    in_req_seen <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
