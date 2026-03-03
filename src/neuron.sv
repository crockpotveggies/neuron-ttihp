`default_nettype none
`include "common/struct/rv_if_t.vh"

module neuron (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire       cmd_valid,
    input             tt_cmd_t cmd,
    output wire       cmd_ready,
    input  wire       out_ready,
    output wire       out_valid,
    output wire [7:0] out_data
`ifdef FORMAL
    ,
    output wire       f_is_cmd_csr,
    output wire       f_is_cmd_weight,
    output wire       f_is_cmd_ucode,
    output wire       f_is_cmd_event,
    output wire       f_cmd_accept,
    output wire       f_fifo_in_ready,
    output wire       f_fifo_out_valid,
    output wire       f_fifo_pop,
    output wire       f_fifo_clear_cmd,
    output wire       f_soft_reset_cmd,
    output wire       f_clear_out_cmd,
    output wire       f_ucode_prog_we,
    output wire [4:0] f_ucode_prog_addr,
    output wire [7:0] f_ucode_prog_data,
    output wire [3:0] f_fifo_in_sid,
    output wire [1:0] f_fifo_in_tag,
    output wire [5:0] f_fifo_in_time,
    output wire [31:0] f_init_rf_flat,
    output wire [31:0] f_rf_state_flat,
    output wire [31:0] f_rf_next_flat,
    output wire [63:0] f_weight_flat,
    output wire [255:0] f_ucode_flat,
    output wire [4:0] f_ucode_ptr_r,
    output wire [3:0] f_ucode_len_r,
    output wire [3:0] f_vector_base0_r,
    output wire [3:0] f_vector_base1_r,
    output wire [3:0] f_vector_base2_r,
    output wire [3:0] f_vector_base3_r,
    output wire [3:0] f_last_sid_r,
    output wire [1:0] f_last_tag_r,
    output wire [5:0] f_last_time_r,
    output wire       f_cmp_ge_r,
    output wire       f_cmp_eq_r,
    output wire       f_spike_flag_r,
    output wire [3:0] f_last_sid_next,
    output wire [1:0] f_last_tag_next,
    output wire [5:0] f_last_time_next,
    output wire       f_cmp_ge_next,
    output wire       f_cmp_eq_next,
    output wire       f_spike_flag_next,
    output wire       f_weight_wr_en_next,
    output wire [3:0] f_weight_wr_idx_next,
    output wire signed [3:0] f_weight_wr_value_next,
    output wire       f_have_out_r,
    output wire [7:0] f_out_data_r,
    output wire       f_emit_pending_next,
    output wire [7:0] f_emit_data_next
`endif
);
    `include "common/packages/event_types.vh"
    localparam [4:0] EXEC_CHUNK_OPS = 5'd1;

    wire       is_cmd_event;
    wire       is_cmd_csr;
    wire       is_cmd_weight;
    wire       is_cmd_ucode;
    wire       cmd_accept;
    wire       fifo_in_ready;
    wire       fifo_out_valid;
    wire       fifo_pop;
    wire       fifo_clear_cmd;
    wire [1:0] fifo_level;
    wire       soft_reset_cmd;
    wire       clear_out_cmd;
    wire       ucode_prog_we;
    wire [4:0] ucode_prog_addr;
    wire [7:0] ucode_prog_data;
    wire       commit_event;

    wire [4:0]  ucode_ptr_r;
    wire [3:0]  ucode_len_r;
    wire [3:0]  vector_base0_r;
    wire [3:0]  vector_base1_r;
    wire [3:0]  vector_base2_r;
    wire [3:0]  vector_base3_r;
    wire [31:0] init_rf_flat;

    wire [255:0] ucode_flat;
    wire [63:0]  weight_flat;

    wire [31:0] rf_state_flat;
    wire [31:0] rf_next_flat;
    wire [3:0]  last_sid_r;
    wire [1:0]  last_tag_r;
    wire [5:0]  last_time_r;
    wire        cmp_ge_r;
    wire        cmp_eq_r;
    wire        spike_flag_r;
    wire        have_out_r;
    wire [7:0]  out_data_r;

    wire [3:0]  last_sid_next;
    wire [1:0]  last_tag_next;
    wire [5:0]  last_time_next;
    wire        cmp_ge_next;
    wire        cmp_eq_next;
    wire        spike_flag_next;
    wire        weight_wr_en_next;
    wire [3:0]  weight_wr_idx_next;
    wire signed [3:0] weight_wr_value_next;
    wire        emit_pending_next;
    wire [7:0]  emit_data_next;
    wire        start_exec;
    wire        continue_exec;
    wire        exec_run;
    wire        exec_chunk_done;
    wire [4:0]  exec_remaining;
    wire [2:0]  exec_count;
    wire [3:0]  exec_start_pc;
    wire [3:0]  start_vector_base;
    wire        fifo_event_space;
    wire [31:0] exec_rf_state_flat;
    wire [3:0]  exec_last_sid_r;
    wire [1:0]  exec_last_tag_r;
    wire [5:0]  exec_last_time_r;
    wire        exec_cmp_ge_r;
    wire        exec_cmp_eq_r;
    wire        exec_spike_flag_r;
    wire        exec_weight_wr_en_in;
    wire [3:0]  exec_weight_wr_idx_in;
    wire signed [3:0] exec_weight_wr_value_in;
    wire        exec_emit_pending_in;
    wire [7:0]  exec_emit_data_in;

    reg         busy_r;
    reg  [31:0] work_rf_state_flat_r;
    reg  [3:0]  work_last_sid_r;
    reg  [1:0]  work_last_tag_r;
    reg  [5:0]  work_last_time_r;
    reg         work_cmp_ge_r;
    reg         work_cmp_eq_r;
    reg         work_spike_flag_r;
    reg         work_weight_wr_en_r;
    reg  [3:0]  work_weight_wr_idx_r;
    reg  signed [3:0] work_weight_wr_value_r;
    reg         work_emit_pending_r;
    reg  [7:0]  work_emit_data_r;
    reg         work_event_valid_r;
    neuron_event_t work_event_r;
    reg  [3:0]  work_pc_r;
    reg  [4:0]  work_remaining_r;

    neuron_event_t fifo_in_payload;
    neuron_event_t fifo_out_payload;
    neuron_event_t exec_event;

    function automatic [3:0] select_vector_base;
        input [1:0] tag;
        input [3:0] base0;
        input [3:0] base1;
        input [3:0] base2;
        input [3:0] base3;
        begin
            case (tag)
                2'd0: select_vector_base = base0;
                2'd1: select_vector_base = base1;
                2'd2: select_vector_base = base2;
                default: select_vector_base = base3;
            endcase
        end
    endfunction

    assign is_cmd_event = (cmd.kind == CMD_EVENT);
    assign is_cmd_csr = (cmd.kind == CMD_CSR);
    assign is_cmd_weight = (cmd.kind == CMD_WEIGHT);
    assign is_cmd_ucode = (cmd.kind == CMD_UCODE);
    assign fifo_event_space = (fifo_level != 2'd2);

`ifdef FORMAL_PROGRESS
    assign cmd_ready = ena && rst_n && (is_cmd_event ? (!have_out_r && fifo_event_space) : 1'b0);
`else
    assign cmd_ready = ena && rst_n && !busy_r && (is_cmd_event ? (!have_out_r && fifo_event_space) : 1'b1);
`endif
    assign cmd_accept = cmd_valid && cmd_ready;
`ifdef FORMAL_SAFETY
    assign start_vector_base = 4'd0;
    assign start_exec = 1'b0;
    assign continue_exec = 1'b0;
    assign exec_run = 1'b0;
    assign fifo_pop = 1'b0;
    assign exec_remaining = 5'd0;
    assign exec_count = 3'd0;
    assign exec_start_pc = 4'd0;
    assign exec_chunk_done = 1'b0;
    assign commit_event = 1'b0;

    assign exec_event.sid = 4'd0;
    assign exec_event.tag = 2'd0;
    assign exec_event.event_time = 6'd0;

    assign exec_rf_state_flat = rf_state_flat;
    assign exec_last_sid_r = last_sid_r;
    assign exec_last_tag_r = last_tag_r;
    assign exec_last_time_r = last_time_r;
    assign exec_cmp_ge_r = cmp_ge_r;
    assign exec_cmp_eq_r = cmp_eq_r;
    assign exec_spike_flag_r = spike_flag_r;
    assign exec_weight_wr_en_in = 1'b0;
    assign exec_weight_wr_idx_in = last_sid_r;
    assign exec_weight_wr_value_in = 4'sd0;
    assign exec_emit_pending_in = 1'b0;
    assign exec_emit_data_in = 8'h00;
`elsif FORMAL_PROGRESS
    assign start_vector_base = 4'd0;
    assign start_exec = ena && rst_n && !have_out_r && fifo_out_valid;
    assign continue_exec = 1'b0;
    assign exec_run = 1'b0;
    assign fifo_pop = start_exec;
    assign exec_remaining = 5'd0;
    assign exec_count = 3'd0;
    assign exec_start_pc = 4'd0;
    assign exec_chunk_done = start_exec;
    assign commit_event = start_exec;

    assign exec_event.sid = fifo_out_payload.sid;
    assign exec_event.tag = fifo_out_payload.tag;
    assign exec_event.event_time = fifo_out_payload.event_time;

    assign exec_rf_state_flat = rf_state_flat;
    assign exec_last_sid_r = last_sid_r;
    assign exec_last_tag_r = last_tag_r;
    assign exec_last_time_r = last_time_r;
    assign exec_cmp_ge_r = cmp_ge_r;
    assign exec_cmp_eq_r = cmp_eq_r;
    assign exec_spike_flag_r = spike_flag_r;
    assign exec_weight_wr_en_in = 1'b0;
    assign exec_weight_wr_idx_in = last_sid_r;
    assign exec_weight_wr_value_in = 4'sd0;
    assign exec_emit_pending_in = 1'b0;
    assign exec_emit_data_in = 8'h00;
`else
    assign start_vector_base = select_vector_base(
        fifo_out_payload.tag,
        vector_base0_r,
        vector_base1_r,
        vector_base2_r,
        vector_base3_r
    );
    assign start_exec = ena && rst_n && !soft_reset_cmd && !busy_r && !have_out_r && fifo_out_valid;
    assign continue_exec = ena && rst_n && !soft_reset_cmd && busy_r && work_event_valid_r;
    assign exec_run = start_exec || continue_exec;
    assign fifo_pop = start_exec;
    assign exec_remaining = busy_r ? work_remaining_r : ({1'b0, ucode_len_r} + 5'd1);
    assign exec_count = (exec_remaining >= EXEC_CHUNK_OPS) ? EXEC_CHUNK_OPS[2:0] : exec_remaining[2:0];
    assign exec_start_pc = busy_r ? work_pc_r : start_vector_base;
    assign exec_chunk_done = exec_run && (exec_remaining <= EXEC_CHUNK_OPS);
    assign commit_event = exec_chunk_done;

    assign exec_event.sid = busy_r ? work_event_r.sid : fifo_out_payload.sid;
    assign exec_event.tag = busy_r ? work_event_r.tag : fifo_out_payload.tag;
    assign exec_event.event_time = busy_r ? work_event_r.event_time : fifo_out_payload.event_time;

    assign exec_rf_state_flat = busy_r ? work_rf_state_flat_r : rf_state_flat;
    assign exec_last_sid_r = busy_r ? work_last_sid_r : last_sid_r;
    assign exec_last_tag_r = busy_r ? work_last_tag_r : last_tag_r;
    assign exec_last_time_r = busy_r ? work_last_time_r : last_time_r;
    assign exec_cmp_ge_r = busy_r ? work_cmp_ge_r : cmp_ge_r;
    assign exec_cmp_eq_r = busy_r ? work_cmp_eq_r : cmp_eq_r;
    assign exec_spike_flag_r = busy_r ? work_spike_flag_r : spike_flag_r;
    assign exec_weight_wr_en_in = busy_r ? work_weight_wr_en_r : 1'b0;
    assign exec_weight_wr_idx_in = busy_r ? work_weight_wr_idx_r : last_sid_r;
    assign exec_weight_wr_value_in = busy_r ? work_weight_wr_value_r : 4'sd0;
    assign exec_emit_pending_in = busy_r ? work_emit_pending_r : 1'b0;
    assign exec_emit_data_in = busy_r ? work_emit_data_r : 8'h00;
`endif

    assign fifo_in_payload.sid = cmd.sid;
    assign fifo_in_payload.tag = cmd.tag;
    assign fifo_in_payload.event_time = cmd.event_time;

`ifndef FORMAL_SAFETY
    tt_event_fifo u_event_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .clear(!ena || fifo_clear_cmd),
        .in_valid(cmd_accept && is_cmd_event),
        .in_payload(fifo_in_payload),
        .in_ready(fifo_in_ready),
        .out_valid(fifo_out_valid),
        .out_payload(fifo_out_payload),
        .out_ready(fifo_pop),
        .level(fifo_level)
    );
`else
    assign fifo_in_ready = 1'b0;
    assign fifo_out_valid = 1'b0;
    assign fifo_out_payload.sid = 4'd0;
    assign fifo_out_payload.tag = 2'd0;
    assign fifo_out_payload.event_time = 6'd0;
    assign fifo_level = 2'd0;
`endif

`ifndef FORMAL_PROGRESS
    neuron_csr u_csr (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_accept(cmd_accept),
        .is_cmd_csr(is_cmd_csr),
        .is_cmd_ucode(is_cmd_ucode),
        .cmd_addr(cmd.addr),
        .cmd_data(cmd.data),
        .soft_reset_cmd(soft_reset_cmd),
        .clear_out_cmd(clear_out_cmd),
        .clear_fifo_cmd(fifo_clear_cmd),
        .ucode_prog_we(ucode_prog_we),
        .ucode_prog_addr(ucode_prog_addr),
        .ucode_prog_data(ucode_prog_data),
        .ucode_ptr_r(ucode_ptr_r),
        .ucode_len_r(ucode_len_r),
        .vector_base0_r(vector_base0_r),
        .vector_base1_r(vector_base1_r),
        .vector_base2_r(vector_base2_r),
        .vector_base3_r(vector_base3_r),
        .init_rf_flat(init_rf_flat)
    );
`else
    assign soft_reset_cmd = 1'b0;
    assign clear_out_cmd = 1'b0;
    assign fifo_clear_cmd = 1'b0;
    assign ucode_prog_we = 1'b0;
    assign ucode_prog_addr = 5'd0;
    assign ucode_prog_data = 8'h00;
    assign ucode_ptr_r = 5'd0;
    assign ucode_len_r = 4'd0;
    assign vector_base0_r = 4'd0;
    assign vector_base1_r = 4'd0;
    assign vector_base2_r = 4'd0;
    assign vector_base3_r = 4'd0;
    assign init_rf_flat = 32'h0000_0700;
`endif

`ifndef FORMAL_PROGRESS
    neuron_ucode_store u_ucode_store (
        .clk(clk),
        .rst_n(rst_n),
        .prog_we(ucode_prog_we),
        .prog_addr(ucode_prog_addr),
        .prog_data(ucode_prog_data),
        .ucode_flat(ucode_flat)
    );
`else
    assign ucode_flat = 256'h0;
`endif

`ifndef FORMAL_PROGRESS
    neuron_weight_bank u_weight_bank (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .direct_we(cmd_accept && is_cmd_weight),
        .direct_idx(cmd.sid),
        .direct_code(cmd.weight_code),
        .exec_we(commit_event && weight_wr_en_next),
        .exec_idx(weight_wr_idx_next),
        .exec_value(weight_wr_value_next),
        .weight_flat(weight_flat)
    );
`else
    assign weight_flat = 64'h0;
`endif

`ifndef FORMAL_SAFETY
`ifndef FORMAL_PROGRESS
    neuron_exec u_exec (
        .execute_valid(exec_run),
        .exec_event(exec_event),
        .start_pc(exec_start_pc),
        .exec_count(exec_count),
        .rf_state_flat(exec_rf_state_flat),
        .weight_flat(weight_flat),
        .ucode_flat(ucode_flat),
        .last_sid_r(exec_last_sid_r),
        .last_tag_r(exec_last_tag_r),
        .last_time_r(exec_last_time_r),
        .cmp_ge_r(exec_cmp_ge_r),
        .cmp_eq_r(exec_cmp_eq_r),
        .spike_flag_r(exec_spike_flag_r),
        .weight_wr_en_in(exec_weight_wr_en_in),
        .weight_wr_idx_in(exec_weight_wr_idx_in),
        .weight_wr_value_in(exec_weight_wr_value_in),
        .emit_pending_in(exec_emit_pending_in),
        .emit_data_in(exec_emit_data_in),
        .rf_next_flat(rf_next_flat),
        .last_sid_next(last_sid_next),
        .last_tag_next(last_tag_next),
        .last_time_next(last_time_next),
        .cmp_ge_next(cmp_ge_next),
        .cmp_eq_next(cmp_eq_next),
        .spike_flag_next(spike_flag_next),
        .weight_wr_en_next(weight_wr_en_next),
        .weight_wr_idx_next(weight_wr_idx_next),
        .weight_wr_value_next(weight_wr_value_next),
        .emit_pending_next(emit_pending_next),
        .emit_data_next(emit_data_next)
    );
`else
    assign rf_next_flat = exec_rf_state_flat;
    assign last_sid_next = exec_last_sid_r;
    assign last_tag_next = exec_last_tag_r;
    assign last_time_next = exec_last_time_r;
    assign cmp_ge_next = exec_cmp_ge_r;
    assign cmp_eq_next = exec_cmp_eq_r;
    assign spike_flag_next = exec_spike_flag_r;
    assign weight_wr_en_next = 1'b0;
    assign weight_wr_idx_next = exec_last_sid_r;
    assign weight_wr_value_next = 4'sd0;
    assign emit_pending_next = 1'b0;
    assign emit_data_next = 8'h00;
`endif
`else
    assign rf_next_flat = exec_rf_state_flat;
    assign last_sid_next = exec_last_sid_r;
    assign last_tag_next = exec_last_tag_r;
    assign last_time_next = exec_last_time_r;
    assign cmp_ge_next = exec_cmp_ge_r;
    assign cmp_eq_next = exec_cmp_eq_r;
    assign spike_flag_next = exec_spike_flag_r;
    assign weight_wr_en_next = 1'b0;
    assign weight_wr_idx_next = exec_last_sid_r;
    assign weight_wr_value_next = 4'sd0;
    assign emit_pending_next = 1'b0;
    assign emit_data_next = 8'h00;
`endif

    neuron_state u_state (
        .clk(clk),
        .rst_n(rst_n),
        .ena(ena),
        .init_rf_flat(init_rf_flat),
        .soft_reset_cmd(soft_reset_cmd),
        .clear_out_cmd(clear_out_cmd),
        .out_ready(out_ready),
        .commit_event(commit_event),
        .rf_next_flat(rf_next_flat),
        .last_sid_next(last_sid_next),
        .last_tag_next(last_tag_next),
        .last_time_next(last_time_next),
        .cmp_ge_next(cmp_ge_next),
        .cmp_eq_next(cmp_eq_next),
        .spike_flag_next(spike_flag_next),
        .emit_pending_next(emit_pending_next),
        .emit_data_next(emit_data_next),
        .rf_state_flat(rf_state_flat),
        .last_sid_r(last_sid_r),
        .last_tag_r(last_tag_r),
        .last_time_r(last_time_r),
        .cmp_ge_r(cmp_ge_r),
        .cmp_eq_r(cmp_eq_r),
        .spike_flag_r(spike_flag_r),
        .have_out_r(have_out_r),
        .out_data_r(out_data_r)
    );

`ifdef FORMAL_PROGRESS
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r <= 1'b0;
            work_rf_state_flat_r <= 32'h0000_0000;
            work_last_sid_r <= 4'd0;
            work_last_tag_r <= 2'd0;
            work_last_time_r <= 6'd0;
            work_cmp_ge_r <= 1'b0;
            work_cmp_eq_r <= 1'b0;
            work_spike_flag_r <= 1'b0;
            work_weight_wr_en_r <= 1'b0;
            work_weight_wr_idx_r <= 4'd0;
            work_weight_wr_value_r <= 4'sd0;
            work_emit_pending_r <= 1'b0;
            work_emit_data_r <= 8'h00;
            work_event_valid_r <= 1'b0;
            work_event_r.sid <= 4'd0;
            work_event_r.tag <= 2'd0;
            work_event_r.event_time <= 6'd0;
            work_pc_r <= 4'd0;
            work_remaining_r <= 5'd0;
        end else begin
            busy_r <= 1'b0;
            work_rf_state_flat_r <= 32'h0000_0000;
            work_last_sid_r <= 4'd0;
            work_last_tag_r <= 2'd0;
            work_last_time_r <= 6'd0;
            work_cmp_ge_r <= 1'b0;
            work_cmp_eq_r <= 1'b0;
            work_spike_flag_r <= 1'b0;
            work_weight_wr_en_r <= 1'b0;
            work_weight_wr_idx_r <= 4'd0;
            work_weight_wr_value_r <= 4'sd0;
            work_emit_pending_r <= 1'b0;
            work_emit_data_r <= 8'h00;
            work_event_valid_r <= 1'b0;
            work_event_r.sid <= 4'd0;
            work_event_r.tag <= 2'd0;
            work_event_r.event_time <= 6'd0;
            work_pc_r <= 4'd0;
            work_remaining_r <= 5'd0;
        end
    end
`else
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r <= 1'b0;
            work_rf_state_flat_r <= 32'h0000_0000;
            work_last_sid_r <= 4'd0;
            work_last_tag_r <= 2'd0;
            work_last_time_r <= 6'd0;
            work_cmp_ge_r <= 1'b0;
            work_cmp_eq_r <= 1'b0;
            work_spike_flag_r <= 1'b0;
            work_weight_wr_en_r <= 1'b0;
            work_weight_wr_idx_r <= 4'd0;
            work_weight_wr_value_r <= 4'sd0;
            work_emit_pending_r <= 1'b0;
            work_emit_data_r <= 8'h00;
            work_event_valid_r <= 1'b0;
            work_event_r.sid <= 4'd0;
            work_event_r.tag <= 2'd0;
            work_event_r.event_time <= 6'd0;
            work_pc_r <= 4'd0;
            work_remaining_r <= 5'd0;
        end else begin
            if (!ena) begin
                busy_r <= 1'b0;
                work_rf_state_flat_r <= 32'h0000_0000;
                work_last_sid_r <= 4'd0;
                work_last_tag_r <= 2'd0;
                work_last_time_r <= 6'd0;
                work_cmp_ge_r <= 1'b0;
                work_cmp_eq_r <= 1'b0;
                work_spike_flag_r <= 1'b0;
                work_weight_wr_en_r <= 1'b0;
                work_weight_wr_idx_r <= 4'd0;
                work_weight_wr_value_r <= 4'sd0;
                work_emit_pending_r <= 1'b0;
                work_emit_data_r <= 8'h00;
                work_event_valid_r <= 1'b0;
                work_event_r.sid <= 4'd0;
                work_event_r.tag <= 2'd0;
                work_event_r.event_time <= 6'd0;
                work_pc_r <= 4'd0;
                work_remaining_r <= 5'd0;
            end else if (soft_reset_cmd) begin
                busy_r <= 1'b0;
                work_rf_state_flat_r <= 32'h0000_0000;
                work_last_sid_r <= 4'd0;
                work_last_tag_r <= 2'd0;
                work_last_time_r <= 6'd0;
                work_cmp_ge_r <= 1'b0;
                work_cmp_eq_r <= 1'b0;
                work_spike_flag_r <= 1'b0;
                work_weight_wr_en_r <= 1'b0;
                work_weight_wr_idx_r <= 4'd0;
                work_weight_wr_value_r <= 4'sd0;
                work_emit_pending_r <= 1'b0;
                work_emit_data_r <= 8'h00;
                work_event_valid_r <= 1'b0;
                work_event_r.sid <= 4'd0;
                work_event_r.tag <= 2'd0;
                work_event_r.event_time <= 6'd0;
                work_pc_r <= 4'd0;
                work_remaining_r <= 5'd0;
            end else if (exec_run) begin
                if (exec_chunk_done) begin
                    busy_r <= 1'b0;
                    work_rf_state_flat_r <= 32'h0000_0000;
                    work_last_sid_r <= 4'd0;
                    work_last_tag_r <= 2'd0;
                    work_last_time_r <= 6'd0;
                    work_cmp_ge_r <= 1'b0;
                    work_cmp_eq_r <= 1'b0;
                    work_spike_flag_r <= 1'b0;
                    work_weight_wr_en_r <= 1'b0;
                    work_weight_wr_idx_r <= 4'd0;
                    work_weight_wr_value_r <= 4'sd0;
                    work_emit_pending_r <= 1'b0;
                    work_emit_data_r <= 8'h00;
                    work_event_valid_r <= 1'b0;
                    work_event_r.sid <= 4'd0;
                    work_event_r.tag <= 2'd0;
                    work_event_r.event_time <= 6'd0;
                    work_pc_r <= 4'd0;
                    work_remaining_r <= 5'd0;
                end else begin
                    busy_r <= 1'b1;
                    work_rf_state_flat_r <= rf_next_flat;
                    work_last_sid_r <= last_sid_next;
                    work_last_tag_r <= last_tag_next;
                    work_last_time_r <= last_time_next;
                    work_cmp_ge_r <= cmp_ge_next;
                    work_cmp_eq_r <= cmp_eq_next;
                    work_spike_flag_r <= spike_flag_next;
                    work_weight_wr_en_r <= weight_wr_en_next;
                    work_weight_wr_idx_r <= weight_wr_idx_next;
                    work_weight_wr_value_r <= weight_wr_value_next;
                    work_emit_pending_r <= emit_pending_next;
                    work_emit_data_r <= emit_data_next;
                    work_event_valid_r <= 1'b1;
                    if (!busy_r) begin
                        work_event_r.sid <= fifo_out_payload.sid;
                        work_event_r.tag <= fifo_out_payload.tag;
                        work_event_r.event_time <= fifo_out_payload.event_time;
                    end
                    work_pc_r <= exec_start_pc + exec_count;
                    work_remaining_r <= exec_remaining - exec_count;
                end
            end
        end
    end
`endif

    assign out_valid = have_out_r;
    assign out_data = out_data_r;

`ifdef FORMAL
    assign f_is_cmd_csr = is_cmd_csr;
    assign f_is_cmd_weight = is_cmd_weight;
    assign f_is_cmd_ucode = is_cmd_ucode;
    assign f_is_cmd_event = is_cmd_event;
    assign f_cmd_accept = cmd_accept;
    assign f_fifo_in_ready = fifo_in_ready;
    assign f_fifo_out_valid = fifo_out_valid;
    assign f_fifo_pop = fifo_pop;
    assign f_fifo_clear_cmd = fifo_clear_cmd;
    assign f_soft_reset_cmd = soft_reset_cmd;
    assign f_clear_out_cmd = clear_out_cmd;
    assign f_ucode_prog_we = ucode_prog_we;
    assign f_ucode_prog_addr = ucode_prog_addr;
    assign f_ucode_prog_data = ucode_prog_data;
    assign f_fifo_in_sid = fifo_in_payload.sid;
    assign f_fifo_in_tag = fifo_in_payload.tag;
    assign f_fifo_in_time = fifo_in_payload.event_time;
    assign f_init_rf_flat = init_rf_flat;
    assign f_rf_state_flat = rf_state_flat;
    assign f_rf_next_flat = rf_next_flat;
    assign f_weight_flat = weight_flat;
    assign f_ucode_flat = ucode_flat;
    assign f_ucode_ptr_r = ucode_ptr_r;
    assign f_ucode_len_r = ucode_len_r;
    assign f_vector_base0_r = vector_base0_r;
    assign f_vector_base1_r = vector_base1_r;
    assign f_vector_base2_r = vector_base2_r;
    assign f_vector_base3_r = vector_base3_r;
    assign f_last_sid_r = last_sid_r;
    assign f_last_tag_r = last_tag_r;
    assign f_last_time_r = last_time_r;
    assign f_cmp_ge_r = cmp_ge_r;
    assign f_cmp_eq_r = cmp_eq_r;
    assign f_spike_flag_r = spike_flag_r;
    assign f_last_sid_next = last_sid_next;
    assign f_last_tag_next = last_tag_next;
    assign f_last_time_next = last_time_next;
    assign f_cmp_ge_next = cmp_ge_next;
    assign f_cmp_eq_next = cmp_eq_next;
    assign f_spike_flag_next = spike_flag_next;
    assign f_weight_wr_en_next = weight_wr_en_next;
    assign f_weight_wr_idx_next = weight_wr_idx_next;
    assign f_weight_wr_value_next = weight_wr_value_next;
    assign f_have_out_r = have_out_r;
    assign f_out_data_r = out_data_r;
    assign f_emit_pending_next = emit_pending_next;
    assign f_emit_data_next = emit_data_next;
`endif
endmodule

`default_nettype wire
