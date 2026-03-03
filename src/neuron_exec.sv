`default_nettype none
`include "src/common/struct/rv_if_t.vh"

module neuron_exec (
    input  wire        execute_valid,
    input              neuron_event_t exec_event,
    input  wire [3:0]  start_pc,
    input  wire [2:0]  exec_count,
    input  wire [31:0] rf_state_flat,
    input  wire [63:0] weight_flat,
    input  wire [255:0] ucode_flat,
    input  wire [3:0]  last_sid_r,
    input  wire [1:0]  last_tag_r,
    input  wire [5:0]  last_time_r,
    input  wire        cmp_ge_r,
    input  wire        cmp_eq_r,
    input  wire        spike_flag_r,
    input  wire        weight_wr_en_in,
    input  wire [3:0]  weight_wr_idx_in,
    input  wire signed [3:0] weight_wr_value_in,
    input  wire        emit_pending_in,
    input  wire [7:0]  emit_data_in,
    output reg  [31:0] rf_next_flat,
    output reg  [3:0]  last_sid_next,
    output reg  [1:0]  last_tag_next,
    output reg  [5:0]  last_time_next,
    output reg         cmp_ge_next,
    output reg         cmp_eq_next,
    output reg         spike_flag_next,
    output reg         weight_wr_en_next,
    output reg  [3:0]  weight_wr_idx_next,
    output reg  signed [3:0] weight_wr_value_next,
    output reg         emit_pending_next,
    output reg  [7:0]  emit_data_next
);
    `include "src/common/packages/event_types.vh"

    integer step;
    integer instr_index;
    integer trace_cmp;
    localparam integer EXEC_CHUNK_OPS = 1;

    reg [15:0]       instr_word;
    reg [4:0]        instr_op;
    reg [2:0]        instr_rd;
    reg [2:0]        instr_ra;
    reg [2:0]        instr_rb;
    reg [2:0]        instr_k;
    reg signed [3:0] instr_imm4;
    reg signed [3:0] weight_shadow;

    function automatic signed [3:0] sat4;
        input integer value;
        begin
            if (value > 7)
                sat4 = 4'sd7;
            else if (value < -8)
                sat4 = -4'sd8;
            else
                sat4 = value[3:0];
        end
    endfunction

    function automatic signed [3:0] imm4_from_fields;
        input [2:0] rb_bits;
        input [2:0] k_bits;
        reg [3:0] raw;
        begin
            raw = {rb_bits[0], k_bits};
            imm4_from_fields = $signed(raw);
        end
    endfunction

    function automatic signed [3:0] ternary_clamp;
        input signed [3:0] value;
        begin
            if (value > 0)
                ternary_clamp = 4'sd1;
            else if (value < 0)
                ternary_clamp = -4'sd1;
            else
                ternary_clamp = 4'sd0;
        end
    endfunction

    function automatic signed [3:0] get_reg4;
        input [31:0] flat;
        input integer lane;
        begin
            get_reg4 = $signed(flat[lane*4 +: 4]);
        end
    endfunction

    function automatic [31:0] set_reg4;
        input [31:0] flat;
        input integer lane;
        input signed [3:0] value;
        reg [31:0] tmp;
        begin
            tmp = flat;
            tmp[lane*4 +: 4] = value;
            set_reg4 = tmp;
        end
    endfunction

    function automatic signed [3:0] get_weight4;
        input [63:0] flat;
        input [3:0] lane;
        begin
            get_weight4 = $signed(flat[lane*4 +: 4]);
        end
    endfunction

    function automatic [15:0] get_instr16;
        input [255:0] flat;
        input integer lane;
        begin
            get_instr16 = flat[lane*16 +: 16];
        end
    endfunction

    function automatic signed [3:0] select_weight_shadow;
        input [3:0] sid;
        input [63:0] weight_bus;
        input       wr_en;
        input [3:0] wr_idx;
        input signed [3:0] wr_val;
        begin
            if (wr_en && (wr_idx == sid))
                select_weight_shadow = wr_val;
            else
                select_weight_shadow = get_weight4(weight_bus, sid);
        end
    endfunction

    function automatic [7:0] pack_emit_data;
        input [1:0] tag;
        input [3:0] sid;
        input       spike;
        begin
            pack_emit_data = {1'b1, tag, sid, spike};
        end
    endfunction

    always @* begin
        // Start from the current architectural snapshot, then let one micro-op mutate the shadow state.
        rf_next_flat = rf_state_flat;
        last_sid_next = last_sid_r;
        last_tag_next = last_tag_r;
        last_time_next = last_time_r;
        cmp_ge_next = cmp_ge_r;
        cmp_eq_next = cmp_eq_r;
        spike_flag_next = spike_flag_r;
        weight_wr_en_next = weight_wr_en_in;
        weight_wr_idx_next = weight_wr_idx_in;
        weight_wr_value_next = weight_wr_value_in;
        emit_pending_next = emit_pending_in;
        emit_data_next = emit_data_in;

        if (execute_valid) begin
            for (step = 0; step < EXEC_CHUNK_OPS; step = step + 1) begin
                if (step < exec_count) begin
                    instr_index = (start_pc + step) & 15;
                    instr_word = get_instr16(ucode_flat, instr_index);
                    instr_op = instr_word[15:11];
                    instr_rd = instr_word[10:8];
                    instr_ra = instr_word[7:5];
                    instr_rb = instr_word[4:2];
                    instr_k = instr_word[2:0];
                    instr_imm4 = imm4_from_fields(instr_rb, instr_k);
                    // Later ops in the same event see a staged writeback immediately through this shadow value.
                    weight_shadow = select_weight_shadow(
                        last_sid_next,
                        weight_flat,
                        weight_wr_en_next,
                        weight_wr_idx_next,
                        weight_wr_value_next
                    );

                    case (instr_op)
                        OP_LDI: rf_next_flat = set_reg4(rf_next_flat, instr_rd, instr_imm4);
                        OP_RECV: begin
                            last_sid_next = exec_event.sid;
                            last_tag_next = exec_event.tag;
                            last_time_next = exec_event.event_time;
                        end

                        OP_ACCUM_W: begin
                            weight_shadow = select_weight_shadow(
                                last_sid_next,
                                weight_flat,
                                weight_wr_en_next,
                                weight_wr_idx_next,
                                weight_wr_value_next
                            );
                            rf_next_flat = set_reg4(rf_next_flat, 6, weight_shadow);
                            rf_next_flat = set_reg4(
                                rf_next_flat,
                                1,
                                sat4(get_reg4(rf_next_flat, 1) + weight_shadow)
                            );
                        end

                        OP_LEAK: rf_next_flat = set_reg4(
                            rf_next_flat,
                            0,
                            sat4(get_reg4(rf_next_flat, 0) - (get_reg4(rf_next_flat, 0) >>> instr_k[1:0]))
                        );

                        OP_INTEG: rf_next_flat = set_reg4(
                            rf_next_flat,
                            0,
                            sat4(get_reg4(rf_next_flat, 0) + get_reg4(rf_next_flat, 1))
                        );

                        OP_SPIKE_IF_GE: spike_flag_next = (
                            get_reg4(rf_next_flat, 0) >= get_reg4(rf_next_flat, 2)
                        );

                        OP_RESET: begin
                            // RESET is spike-conditional in the reduced ISA, so non-spiking events leave V unchanged.
                            if (spike_flag_next) begin
                                case (instr_k[1:0])
                                    2'b00: rf_next_flat = set_reg4(rf_next_flat, 0, 4'sd0);
                                    2'b01: rf_next_flat = set_reg4(
                                        rf_next_flat,
                                        0,
                                        sat4(get_reg4(rf_next_flat, 0) - get_reg4(rf_next_flat, 2))
                                    );
                                    2'b10: begin
                                        if (get_reg4(rf_next_flat, 0) > get_reg4(rf_next_flat, 2))
                                            rf_next_flat = set_reg4(rf_next_flat, 0, get_reg4(rf_next_flat, 2));
                                    end
                                    default: begin
                                    end
                                endcase
                            end
                        end

                        OP_REFRACT: begin
                            if (spike_flag_next) begin
                                rf_next_flat = set_reg4(rf_next_flat, 3, instr_imm4);
                            end else if (get_reg4(rf_next_flat, 3) > 0) begin
                                rf_next_flat = set_reg4(
                                    rf_next_flat,
                                    3,
                                    sat4(get_reg4(rf_next_flat, 3) - (get_reg4(rf_next_flat, 3) >>> instr_k[1:0]))
                                );
                            end
                        end

                        OP_EMIT: begin
                            if (!emit_pending_next) begin
                                emit_pending_next = 1'b1;
                                emit_data_next = pack_emit_data(instr_k[1:0], last_sid_next, spike_flag_next);
                            end
                        end

                        OP_TDEC: rf_next_flat = set_reg4(
                            rf_next_flat,
                            instr_rd[0] ? 5 : 4,
                            sat4(
                                get_reg4(rf_next_flat, instr_rd[0] ? 5 : 4) -
                                (get_reg4(rf_next_flat, instr_rd[0] ? 5 : 4) >>> instr_k[1:0])
                            )
                        );
                        OP_TINC: rf_next_flat = set_reg4(
                            rf_next_flat,
                            instr_rd[0] ? 5 : 4,
                            sat4(get_reg4(rf_next_flat, instr_rd[0] ? 5 : 4) + instr_imm4)
                        );

                        OP_STDP_LITE: begin
                            weight_shadow = select_weight_shadow(
                                last_sid_next,
                                weight_flat,
                                weight_wr_en_next,
                                weight_wr_idx_next,
                                weight_wr_value_next
                            );
                            trace_cmp = get_reg4(rf_next_flat, 4) - get_reg4(rf_next_flat, 5);
                            case (instr_k[1:0])
                                2'b01: begin
                                    if (spike_flag_next && (get_reg4(rf_next_flat, 4) > 0))
                                        weight_shadow = ternary_clamp(weight_shadow + 4'sd1);
                                end
                                2'b10: begin
                                    if (!spike_flag_next && (get_reg4(rf_next_flat, 5) > 0))
                                        weight_shadow = ternary_clamp(weight_shadow - 4'sd1);
                                end
                                2'b11: begin
                                    if (trace_cmp > 0)
                                        weight_shadow = ternary_clamp(weight_shadow + 4'sd1);
                                    else if (trace_cmp < 0)
                                        weight_shadow = ternary_clamp(weight_shadow - 4'sd1);
                                end
                                default: begin
                                end
                            endcase
                            weight_wr_en_next = 1'b1;
                            weight_wr_idx_next = last_sid_next;
                            weight_wr_value_next = weight_shadow;
                        end

                        default: begin
                            // Unassigned opcode slots are treated as no-ops in the reduced 12-op ISA.
                        end
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
