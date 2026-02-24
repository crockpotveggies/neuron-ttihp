`default_nettype none

module neuron_learning (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire       soft_reset_fire,
    input  wire       active_event,
    input  wire       is_tick,
    input  wire       is_prog_addr,
    input  wire [3:0] addr_low,
    input  wire       learn_en,
    input  wire       post_spike_pulse,
    input  wire       learn_start_pulse,
    input  wire [1:0] w_ptr_curr,
    input  wire [1:0] w_addr_curr,
    output reg  [15:0] pre_trace,
    output reg         post_trace,
    output reg         learn_pending,
    output reg  [3:0]  learn_ptr,
    output wire        ltp_we,
    output wire [3:0]  ltp_idx,
    output wire [1:0]  ltp_wdata,
    output wire        ltd_we,
    output wire [3:0]  ltd_idx,
    output wire [1:0]  ltd_wdata
);
    `include "neuron_math.vh"

    assign ltp_we    = active_event && learn_pending && pre_trace[learn_ptr];
    assign ltp_idx   = learn_ptr;
    assign ltp_wdata = sat_inc2(w_ptr_curr);

    assign ltd_we    = active_event && !is_tick && is_prog_addr && learn_en && post_trace;
    assign ltd_idx   = addr_low;
    assign ltd_wdata = sat_dec2(w_addr_curr);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_trace    <= 16'd0;
            post_trace   <= 1'b0;
            learn_pending<= 1'b0;
            learn_ptr    <= 4'd0;

        end else if (soft_reset_fire) begin
            pre_trace     <= 16'd0;
            post_trace    <= 1'b0;
            learn_pending <= 1'b0;
            learn_ptr     <= 4'd0;

        end else if (ena && active_event) begin
            // Serial LTP progression first.
            if (learn_pending) begin
                if (pre_trace[learn_ptr])
                    pre_trace[learn_ptr] <= 1'b0;

                if (learn_ptr == 4'd15) begin
                    learn_pending <= 1'b0;
                    learn_ptr     <= 4'd0;
                end else begin
                    learn_ptr <= learn_ptr + 4'd1;
                end
            end

            // Bound LTD window on ticks.
            if (is_tick)
                post_trace <= 1'b0;

            // Capture pre-trace on programmable pre-events.
            if (!is_tick && is_prog_addr)
                pre_trace[addr_low] <= 1'b1;

            // Post-spike re-arms post_trace.
            if (post_spike_pulse)
                post_trace <= 1'b1;

            // LIF post-spike starts a fresh learning scan.
            if (learn_start_pulse && learn_en) begin
                learn_pending <= 1'b1;
                learn_ptr     <= 4'd0;
            end
        end
    end
endmodule

`default_nettype wire
