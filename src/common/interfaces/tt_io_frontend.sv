`default_nettype none

`include "common/struct/rv_if_t.vh"

module tt_io_frontend (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire [7:0] ui_in,
    input  wire [7:0] uio_in,
    input        io_frontend_ctrl_t frontend_ctrl,
    output reg  [7:0] ui_in_sync,
    output reg  [7:0] uio_in_sync,
    output reg        in_req_seen,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);
    reg [7:0] ui_in_meta;
    reg [7:0] ui_in_stage;
    reg [7:0] ui_in_live;
    reg [7:0] uio_in_meta;
    reg [7:0] uio_in_stage;
    reg [7:0] uio_in_live;

    wire in_req;
    wire host_ready;

    assign in_req = uio_in_live[0];
    assign host_ready = ena && rst_n && frontend_ctrl.in_ready && !in_req_seen;

    assign uio_out = {6'b0, frontend_ctrl.out_valid, host_ready};
    assign uio_oe = {6'b0, 1'b1, 1'b1};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ui_in_meta <= 8'h00;
            ui_in_stage <= 8'h00;
            ui_in_live <= 8'h00;
            ui_in_sync <= 8'h00;
            uio_in_meta <= 8'h00;
            uio_in_stage <= 8'h00;
            uio_in_live <= 8'h00;
            uio_in_sync <= 8'h00;
            in_req_seen <= 1'b0;
        end else begin
            ui_in_meta <= ui_in;
            ui_in_stage <= ui_in_meta;
            ui_in_live <= ui_in_stage;
            uio_in_meta <= uio_in;
            uio_in_stage <= uio_in_meta;
            uio_in_live <= uio_in_stage;

            if (!ena) begin
                ui_in_sync <= 8'h00;
                uio_in_sync <= 8'h00;
                in_req_seen <= 1'b0;
            end else begin
                uio_in_sync[1] <= uio_in_live[1];

                if (frontend_ctrl.in_fire) begin
                    ui_in_sync <= 8'h00;
                    uio_in_sync[7:2] <= 6'h00;
                    uio_in_sync[0] <= 1'b0;
                end else if (!in_req_seen && !uio_in_sync[0] && in_req) begin
                    ui_in_sync <= ui_in_live;
                    uio_in_sync[7:2] <= uio_in_live[7:2];
                    uio_in_sync[0] <= uio_in_live[0];
                end

                if (!in_req) begin
                    in_req_seen <= 1'b0;
                end else if (!in_req_seen && !uio_in_sync[0]) begin
                    in_req_seen <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
