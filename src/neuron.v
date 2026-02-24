`default_nettype none

module neuron (
`ifdef USE_POWER_PINS
    input  wire VGND,
    input  wire VPWR,
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
    `include "neuron_defs.vh"

    // Front-end synchronized interface signals (kept visible for formal).
    wire [7:0] ui_in_sync;
    wire [7:0] uio_in_sync;
    wire in_req_seen;

    wire in_ack;
    wire out_req;
    wire in_fire;
    wire out_fire;

    wire [7:0] in_data = ui_in_sync;

    // Decoded input event fields.
    wire       is_tick;
    wire       polarity;
    wire [5:0] addr;
    wire [1:0] cfg_op;
    wire [3:0] cfg_arg;

    wire is_reset_cmd;
    wire is_arm_cmd;
    wire is_cfg_cmd;
    wire is_special_cmd;

    wire normal_event = in_fire && !is_special_cmd;
    wire arm_event = in_fire && is_arm_cmd;
    wire soft_reset_fire = in_fire && is_reset_cmd;

    // Configured runtime mode.
    reg [1:0] mode;
    reg       stream_act;
    reg       learn_en;

    // Mode states (kept at top for debug/formal visibility).
    reg [7:0] lif_V;

    reg [7:0] td_curr;
    reg [7:0] td_prev;
    reg [7:0] td_last_diff;

    reg       fst_armed;
    reg [7:0] fst_t;
    reg [7:0] fst_last_t;

    reg [3:0] conv_shift;
    reg       spike_seen_this_tick;
    reg [2:0] conv_last_sum;

    // Synapse state and outputs (kept visible for formal).
    wire [31:0] wtab;
    wire [3:0]  pending_widx;
    wire        is_prog_addr;
    wire [1:0]  w_eff;

    // Learning state and write intents (kept visible for formal).
    wire [15:0] pre_trace;
    wire        post_trace;
    wire        learn_pending;
    wire [3:0]  learn_ptr;

    wire        ltp_we;
    wire [3:0]  ltp_idx;
    wire [1:0]  ltp_wdata;
    wire        ltd_we;
    wire [3:0]  ltd_idx;
    wire [1:0]  ltd_wdata;

    wire [1:0] w_ptr_curr  = wtab[{learn_ptr, 1'b0} +: 2];
    wire [1:0] w_addr_curr = wtab[{addr[3:0], 1'b0} +: 2];

    // Output queue state (kept visible for formal).
    wire       have_out;
    wire [7:0] out_data_r;

    // Per-mode activity gates.
    wire mode_lif_evt  = normal_event && (mode == `NEURON_MODE_LIF);
    wire mode_td_evt   = normal_event && (mode == `NEURON_MODE_TD);
    wire mode_fst_evt  = normal_event && (mode == `NEURON_MODE_FST);
    wire mode_conv_evt = normal_event && (mode == `NEURON_MODE_CONV);

    // Per-mode combinational intents and next values.
    wire [7:0] lif_V_next;
    wire lif_emit_valid;
    wire [7:0] lif_emit_data;
    wire lif_post_spike;
    wire lif_learn_start;

    wire [7:0] td_curr_next;
    wire [7:0] td_prev_next;
    wire [7:0] td_last_diff_next;
    wire td_emit_valid;
    wire [7:0] td_emit_data;
    wire td_post_spike;
    wire td_learn_start;

    wire fst_armed_next;
    wire [7:0] fst_t_next;
    wire [7:0] fst_last_t_next;
    wire fst_emit_valid;
    wire [7:0] fst_emit_data;
    wire fst_post_spike;
    wire fst_learn_start;

    wire [3:0] conv_shift_next;
    wire spike_seen_this_tick_next;
    wire [2:0] conv_last_sum_next;
    wire conv_emit_valid;
    wire [7:0] conv_emit_data;
    wire conv_post_spike;
    wire conv_learn_start;

    wire mode_emit_valid;
    wire [7:0] mode_emit_data;
    wire mode_post_spike;
    wire mode_learn_start;

    // Front-end IO hardening and handshake.
    (* keep_hierarchy = "yes" *) neuron_io_frontend u_frontend (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .ui_in(ui_in),
        .uio_in(uio_in),
        .have_out(have_out),
        .ui_in_sync(ui_in_sync),
        .uio_in_sync(uio_in_sync),
        .in_req_seen(in_req_seen),
        .in_ack(in_ack),
        .out_req(out_req),
        .in_fire(in_fire),
        .out_fire(out_fire),
        .uio_out(uio_out),
        .uio_oe(uio_oe)
    );

    (* keep_hierarchy = "yes" *) neuron_event_decode u_decode (
        .in_data(in_data),
        .uio_data(uio_in_sync),
        .is_tick(is_tick),
        .polarity(polarity),
        .addr(addr),
        .cfg_op(cfg_op),
        .cfg_arg(cfg_arg),
        .is_reset_cmd(is_reset_cmd),
        .is_arm_cmd(is_arm_cmd),
        .is_cfg_cmd(is_cfg_cmd),
        .is_special_cmd(is_special_cmd)
    );

    (* keep_hierarchy = "yes" *) neuron_synapse_bank u_syn (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .addr(addr),
        .polarity(polarity),
        .cfg_set_widx_fire(in_fire && is_cfg_cmd && (cfg_op == 2'b00)),
        .cfg_write_w_fire(in_fire && is_cfg_cmd && (cfg_op == 2'b01)),
        .cfg_arg(cfg_arg),
        .ltp_we(ltp_we),
        .ltp_idx(ltp_idx),
        .ltp_wdata(ltp_wdata),
        .ltd_we(ltd_we),
        .ltd_idx(ltd_idx),
        .ltd_wdata(ltd_wdata),
        .wtab(wtab),
        .pending_widx(pending_widx),
        .is_prog_addr(is_prog_addr),
        .w_eff(w_eff)
    );

    (* keep_hierarchy = "yes" *) neuron_mode_lif u_lif (
        .lif_V(lif_V),
        .w_eff(w_eff),
        .active_event(mode_lif_evt),
        .is_tick(is_tick),
        .stream_act(stream_act),
        .learn_en(learn_en),
        .have_out(have_out),
        .lif_V_next(lif_V_next),
        .emit_valid(lif_emit_valid),
        .emit_data(lif_emit_data),
        .post_spike_pulse(lif_post_spike),
        .learn_start_pulse(lif_learn_start)
    );

    (* keep_hierarchy = "yes" *) neuron_mode_td u_td (
        .td_curr(td_curr),
        .td_prev(td_prev),
        .td_last_diff(td_last_diff),
        .w_eff(w_eff),
        .active_event(mode_td_evt),
        .is_tick(is_tick),
        .stream_act(stream_act),
        .have_out(have_out),
        .td_curr_next(td_curr_next),
        .td_prev_next(td_prev_next),
        .td_last_diff_next(td_last_diff_next),
        .emit_valid(td_emit_valid),
        .emit_data(td_emit_data),
        .post_spike_pulse(td_post_spike),
        .learn_start_pulse(td_learn_start)
    );

    (* keep_hierarchy = "yes" *) neuron_mode_fst u_fst (
        .fst_armed(fst_armed),
        .fst_t(fst_t),
        .fst_last_t(fst_last_t),
        .active_event(mode_fst_evt),
        .arm_event(arm_event),
        .is_tick(is_tick),
        .stream_act(stream_act),
        .have_out(have_out),
        .fst_armed_next(fst_armed_next),
        .fst_t_next(fst_t_next),
        .fst_last_t_next(fst_last_t_next),
        .emit_valid(fst_emit_valid),
        .emit_data(fst_emit_data),
        .post_spike_pulse(fst_post_spike),
        .learn_start_pulse(fst_learn_start)
    );

    (* keep_hierarchy = "yes" *) neuron_mode_conv u_conv (
        .conv_shift(conv_shift),
        .spike_seen_this_tick(spike_seen_this_tick),
        .conv_last_sum(conv_last_sum),
        .active_event(mode_conv_evt),
        .is_tick(is_tick),
        .stream_act(stream_act),
        .have_out(have_out),
        .conv_shift_next(conv_shift_next),
        .spike_seen_this_tick_next(spike_seen_this_tick_next),
        .conv_last_sum_next(conv_last_sum_next),
        .emit_valid(conv_emit_valid),
        .emit_data(conv_emit_data),
        .post_spike_pulse(conv_post_spike),
        .learn_start_pulse(conv_learn_start)
    );

    (* keep_hierarchy = "yes" *) neuron_mode_select u_mode_sel (
        .mode(mode),
        .lif_emit_valid(lif_emit_valid),
        .lif_emit_data(lif_emit_data),
        .lif_post_spike(lif_post_spike),
        .lif_learn_start(lif_learn_start),
        .td_emit_valid(td_emit_valid),
        .td_emit_data(td_emit_data),
        .td_post_spike(td_post_spike),
        .td_learn_start(td_learn_start),
        .fst_emit_valid(fst_emit_valid),
        .fst_emit_data(fst_emit_data),
        .fst_post_spike(fst_post_spike),
        .fst_learn_start(fst_learn_start),
        .conv_emit_valid(conv_emit_valid),
        .conv_emit_data(conv_emit_data),
        .conv_post_spike(conv_post_spike),
        .conv_learn_start(conv_learn_start),
        .emit_valid(mode_emit_valid),
        .emit_data(mode_emit_data),
        .post_spike_pulse(mode_post_spike),
        .learn_start_pulse(mode_learn_start)
    );

    (* keep_hierarchy = "yes" *) neuron_learning u_learning (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .soft_reset_fire(soft_reset_fire),
        .active_event(normal_event),
        .is_tick(is_tick),
        .is_prog_addr(is_prog_addr),
        .addr_low(addr[3:0]),
        .learn_en(learn_en),
        .post_spike_pulse(mode_post_spike),
        .learn_start_pulse(mode_learn_start),
        .w_ptr_curr(w_ptr_curr),
        .w_addr_curr(w_addr_curr),
        .pre_trace(pre_trace),
        .post_trace(post_trace),
        .learn_pending(learn_pending),
        .learn_ptr(learn_ptr),
        .ltp_we(ltp_we),
        .ltp_idx(ltp_idx),
        .ltp_wdata(ltp_wdata),
        .ltd_we(ltd_we),
        .ltd_idx(ltd_idx),
        .ltd_wdata(ltd_wdata)
    );

    (* keep_hierarchy = "yes" *) neuron_outq u_outq (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .out_fire(out_fire),
        .emit_valid(mode_emit_valid),
        .emit_data(mode_emit_data),
        .have_out(have_out),
        .out_data_r(out_data_r)
    );

    assign uo_out = out_data_r;

    // Top-level control + mode-state updates.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode       <= `NEURON_MODE_LIF;
            stream_act <= 1'b1;
            learn_en   <= 1'b0;

            lif_V <= 8'd0;

            td_curr <= 8'd0;
            td_prev <= 8'd0;
            td_last_diff <= 8'd0;

            fst_armed  <= 1'b0;
            fst_t      <= 8'd0;
            fst_last_t <= 8'd0;

            conv_shift <= 4'd0;
            spike_seen_this_tick <= 1'b0;
            conv_last_sum <= 3'd0;

        end else if (ena && in_fire) begin
            if (is_reset_cmd) begin
                lif_V <= 8'd0;

                td_curr <= 8'd0;
                td_prev <= 8'd0;
                td_last_diff <= 8'd0;

                fst_armed  <= 1'b0;
                fst_t      <= 8'd0;
                fst_last_t <= 8'd0;

                conv_shift <= 4'd0;
                spike_seen_this_tick <= 1'b0;
                conv_last_sum <= 3'd0;

            end else if (is_cfg_cmd) begin
                if (cfg_op == 2'b10) begin
                    mode       <= cfg_arg[1:0];
                    stream_act <= cfg_arg[2];
                    learn_en   <= cfg_arg[3];
                end

            end else begin
                lif_V <= lif_V_next;

                td_curr <= td_curr_next;
                td_prev <= td_prev_next;
                td_last_diff <= td_last_diff_next;

                fst_armed <= fst_armed_next;
                fst_t <= fst_t_next;
                fst_last_t <= fst_last_t_next;

                conv_shift <= conv_shift_next;
                spike_seen_this_tick <= spike_seen_this_tick_next;
                conv_last_sum <= conv_last_sum_next;
            end
        end
    end
endmodule

`default_nettype wire
