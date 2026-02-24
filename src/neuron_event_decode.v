`default_nettype none

module neuron_event_decode (
    input  wire [7:0] in_data,
    input  wire [7:0] uio_data,
    output wire       is_tick,
    output wire       polarity,
    output wire [5:0] addr,
    output wire [1:0] cfg_op,
    output wire [3:0] cfg_arg,
    output wire       is_reset_cmd,
    output wire       is_arm_cmd,
    output wire       is_cfg_cmd,
    output wire       is_special_cmd
);
    `include "neuron_defs.vh"

    assign is_tick  = in_data[7];
    assign polarity = in_data[6];
    assign addr     = in_data[5:0];

    assign cfg_arg = uio_data[7:4];
    assign cfg_op  = uio_data[3:2];

    assign is_reset_cmd = !is_tick && (addr == `NEURON_ADDR_RESET);
    assign is_arm_cmd   = !is_tick && (addr == `NEURON_ADDR_ARM);
    assign is_cfg_cmd   = !is_tick && (addr == `NEURON_ADDR_CFG);
    assign is_special_cmd = is_reset_cmd || is_arm_cmd || is_cfg_cmd;
endmodule

`default_nettype wire
