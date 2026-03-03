`default_nettype none
`include "src/common/struct/rv_if_t.vh"

module tt_um_crockpotveggies_neuron (
`ifdef USE_POWER_PINS
    input  wire       VGND,
    input  wire       VPWR,
`endif
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    reg  [7:0] ui_in_sync;
    reg  [7:0] uio_in_sync;
    reg        in_req_seen;
    wire [7:0] uio_out_i;
    wire [7:0] uio_oe_i;

    wire       input_req;
    wire       output_ack;
    wire       cmd_accept;
    wire       neuron_cmd_ready;
    wire       neuron_out_valid;
    wire [7:0] neuron_out_data;

    tt_cmd_t host_cmd;
    io_frontend_ctrl_t frontend_ctrl;

    assign input_req = uio_in_sync[0];
    assign output_ack = uio_in_sync[1];
    assign cmd_accept = input_req && neuron_cmd_ready;

    always @* begin
        frontend_ctrl = '0;
        frontend_ctrl.out_valid = neuron_out_valid;
        frontend_ctrl.in_ready = neuron_cmd_ready;
        frontend_ctrl.in_fire = cmd_accept;
    end

    tt_io_frontend u_frontend (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .ui_in(ui_in),
        .uio_in(uio_in),
        .frontend_ctrl(frontend_ctrl),
        .ui_in_sync(ui_in_sync),
        .uio_in_sync(uio_in_sync),
        .in_req_seen(in_req_seen),
        .uio_out(uio_out_i),
        .uio_oe(uio_oe_i)
    );

    tt_event_decode u_decode (
        .in_data(ui_in_sync),
        .uio_data(uio_in_sync),
        .cmd(host_cmd)
    );

    neuron u_neuron (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .cmd_valid(input_req),
        .cmd(host_cmd),
        .cmd_ready(neuron_cmd_ready),
        .out_ready(output_ack),
        .out_valid(neuron_out_valid),
        .out_data(neuron_out_data)
    );

    assign uio_out = uio_out_i;
    assign uio_oe = uio_oe_i;
    assign uo_out = neuron_out_data;
endmodule

`default_nettype wire
