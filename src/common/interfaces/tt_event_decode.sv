`default_nettype none

`include "common/struct/rv_if_t.vh"

module tt_event_decode (
    input  wire [7:0] in_data,
    input  wire [7:0] uio_data,
    output      tt_cmd_t cmd
);
    assign cmd.kind = in_data[7:6];
    assign cmd.addr = in_data[5:2];
    assign cmd.data = {uio_data[7:2], in_data[1:0]};
    assign cmd.sid = in_data[5:2];
    assign cmd.tag = in_data[1:0];
    assign cmd.event_time = uio_data[7:2];
    assign cmd.weight_code = in_data[1:0];
endmodule

`default_nettype wire
