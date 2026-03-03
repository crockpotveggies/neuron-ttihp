`default_nettype none

`include "common/struct/rv_if_t.vh"

module tt_event_fifo (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clear,
    input  wire              in_valid,
    input        neuron_event_t in_payload,
    output wire              in_ready,
    output wire              out_valid,
    output       neuron_event_t out_payload,
    input  wire              out_ready,
    output wire [1:0]        level
);
    reg        slot0_valid;
    reg        slot1_valid;
    reg [11:0] slot0_data;
    reg [11:0] slot1_data;

    wire do_push;
    wire do_pop;
    wire full_now;
    wire [11:0] in_bits;

    assign in_bits = {in_payload.sid, in_payload.tag, in_payload.event_time};
    assign full_now = slot0_valid && slot1_valid;
    assign in_ready = !full_now || (out_ready && slot0_valid);
    assign out_valid = slot0_valid;
    assign out_payload.sid = slot0_data[11:8];
    assign out_payload.tag = slot0_data[7:6];
    assign out_payload.event_time = slot0_data[5:0];
    assign level = {1'b0, slot0_valid} + {1'b0, slot1_valid};

    assign do_push = in_valid && in_ready;
    assign do_pop = slot0_valid && out_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot0_valid <= 1'b0;
            slot1_valid <= 1'b0;
            slot0_data <= 12'h000;
            slot1_data <= 12'h000;
        end else if (clear) begin
            slot0_valid <= 1'b0;
            slot1_valid <= 1'b0;
            slot0_data <= 12'h000;
            slot1_data <= 12'h000;
        end else begin
            case ({do_push, do_pop})
                2'b00: begin
                end

                2'b01: begin
                    slot0_valid <= slot1_valid;
                    slot0_data <= slot1_data;
                    slot1_valid <= 1'b0;
                    slot1_data <= 12'h000;
                end

                2'b10: begin
                    if (!slot0_valid) begin
                        slot0_valid <= 1'b1;
                        slot0_data <= in_bits;
                    end else begin
                        slot1_valid <= 1'b1;
                        slot1_data <= in_bits;
                    end
                end

                2'b11: begin
                    if (slot1_valid) begin
                        slot0_valid <= 1'b1;
                        slot0_data <= slot1_data;
                        slot1_valid <= 1'b1;
                        slot1_data <= in_bits;
                    end else begin
                        slot0_valid <= 1'b1;
                        slot0_data <= in_bits;
                    end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
