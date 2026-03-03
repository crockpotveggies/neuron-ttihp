`default_nettype none

module rv_fifo #(
    // global parameters -- set @ instantiation
    parameter integer ENTRIES = 'd2,   // number of elements
    parameter integer DATAWIDTH = 'd1, // width (bits) of an element
    parameter type    DTYPE = logic[DATAWIDTH-1:0], // parameterized data type
    parameter bit     WRITE_THRU = 1'b0,  // set to enable write-thru mode
    // local/derived parameters
    parameter int     pCW = $clog2(ENTRIES+1),   // Count: from 0 to ENTRIES
    parameter bit     ALWAYS_PUSH_TO_INPUT = 1'b0  //When set, decouples input_q from q_dout.ready to improve timing by lowering its fanout by about half
  )
   (
    // System Signals
    input  logic          clk,
    input  logic          rst_n,

    // general status and control signals
    input  logic               q_enable, // enables pushes
    output logic [pCW-1:0]     q_count,  // from 0 to ENTRIES

    // queue input Interface
    rv_if.rx                 q_din,         // input data

    // queue output Interface
    rv_if.tx                 q_dout         // output data
  );

// *                          bypass path
// *         /------------------------------------------------------------------\
// *        /                                                                    \
// *        |                          +-----+                                    \
// *        |           +--------------|     |---\                                 \
// *        |           |              |     |    \                                 \
// *        |           |              |     |     \                                 \
// *        |           |              +-----+      \                                 \
// * q_din -+-----------------\       storage FFs    \                                 \
// *        |           |      \                      \--------------+\       +----+    \------+\
// *        |  +----+   |       \------------------------------------+ | -----|    |           + |---- q_dout
// *        \--|    |---+--------------------------------------------+/       |    |-----------+/
// *           |    |                                                         |>   |      bypass mux
// *           |>   |                                                         +----+
// *           +----+
// *
// *          Input stage FF                                              Output stage FF
//

`ifndef SYNTHESIS
`ifndef ASSERT_DISABLE
  // make sure that 'ENTRIES' is not zero
  initial begin
    entries_check: assert (ENTRIES > 'd0)
      else $fatal("%m: Illegal value for parameter ENTRIES: %0d", ENTRIES);
  end
`endif
`endif

  // handle the special case of ENTRIES == 'd1 (where pAFW == $clog2(1) == 'd0)
  localparam int POINTER_W = (ENTRIES>3 ? $clog2(ENTRIES-2) : 'd1);
  localparam int pLAST = (ENTRIES>2) ? ENTRIES-3 : 'd0;
  typedef logic[POINTER_W-1:0] pointer_t;

  //----------------------------------------------------------------------------
  // registers and assignments

  logic output_valid;
  logic input_valid;
  logic storage_valid;

  //transfer flags
  logic bypass_que;        // asserted for write_thru
  logic push_to_input;
  logic push_to_output;
  logic input_to_output;
  logic input_to_storage;
  logic storage_to_output;

  // output signals for the 3 different queue stages
  DTYPE input_q;
  DTYPE output_q;
  DTYPE storage_out;

  // compute 'push' and 'pop'
  logic                  q_push, q_pop;

  // muxes will not be instantiated if WRITE_THRU==0
  generate
    if (WRITE_THRU) begin : gen_bypass
      assign bypass_que = (q_count == '0);
      assign q_dout.valid = (bypass_que ? q_din.valid && q_din.ready : output_valid); //FIX ASICCOE-12841 by including q_din.ready here
      assign q_dout.rv_payload = (bypass_que ? q_din : output_q);
      assign q_push = (q_din.valid && q_din.ready && !(bypass_que && q_dout.ready));
      assign q_pop = (output_valid && q_dout.ready && !bypass_que);
    end else begin : gen_no_bypass
      assign bypass_que = 1'b0;
      assign q_dout.valid = output_valid;
      assign q_dout.rv_payload = output_q;
       // trac 260 assign q_push = (q_enable && q_din.ready && q_din.valid);
       assign q_push = (q_din.valid && q_din.ready);
       assign q_pop = (output_valid && q_dout.ready);
     end
   endgenerate

  always_comb begin
    //direct push to output stage if the queue is empty, or if the last entry is
    //being popped.  Otherwise push to input stage
    push_to_output = q_push && ((!output_valid) || (!input_valid && !storage_valid && q_pop));
    push_to_input  = q_push && !(push_to_output) && (ENTRIES>1);

    //direct transfer from input to output stage occurs only if the storage
    //stage is empty and there is a pop
    input_to_output = !storage_valid && input_valid && q_pop && (ENTRIES>1);

    //input to storage transfer occurs if input is valid and storage is not full
    //note that this condition avoids dependency on q_pop so as to reduce fanout
    //on q_pop and hence q_dout.ready.  If a full queue is popped, the input
    //to storage transfer occurs 1 clock cycle after the pop.  This is ok
    //because the input to storage transfer can happen on the next clock cycle
    //to make room for incoming data to arrive in the input queue
    input_to_storage = input_valid && (q_count<ENTRIES[$bits(q_count)-1:0]) && (!input_to_output) && (ENTRIES>2);

    //storage to output transfer occurs if output is popped and storage is valid
    //Note that if q_count==2, the output stage is occupied and either the
    //input stage or the storage stage can contain the second queue entry.
    storage_to_output = storage_valid && q_pop && (ENTRIES>2);

    //the following scenarios should never occur by design
    // input_valid==1   && output_valid==0
    // storage_valid==1 && output_valid==0
  end

  //----------------------------------------------------------------------------
  // the Queue FSM
  //    assert 'ready' if there is/will be room in the queue
  //    assert 'valid' if there is/will be data in the queue
  //    adjust the in/out pointers & count based on push and pop

  //output stage and read/valid/qcount FFs
  always @(posedge clk or negedge rst_n) begin

    // reset everything and clear the queue
    if (rst_n == 1'b0) begin
      // external signals
      q_count      <= '0;
      q_din.ready  <= 1'b0;
      output_valid <= 1'b0;
      // initialize the queue
      output_q     <= DTYPE'('0);

    end else begin

      if(q_push ^ q_pop) begin  //fine grained clock gating condition
        // adjust the count, check for simultaneous push & pop
        if(q_push && !q_pop) q_count <= q_count + 1'd1;
        if(!q_push && q_pop) q_count <= q_count - 1'd1;

        //set or clear output_valid
        if (push_to_output)                       output_valid <= 1'b1;
        else if (q_pop && q_count ==1 && !q_push) output_valid <= 1'b0;
      end

      if(q_pop || (q_push && q_count==0)) begin //fine grained clock gating condition for output_q

        if (push_to_output) begin
          //direct load to output stage
          output_q <= q_din.rv_payload;
        end else if (storage_to_output) begin
          //transfer from storage to output stage
          output_q <= storage_out;
        end else if (input_to_output) begin
          //transfer from input stage to output stage
          output_q <= input_q;
        end
      end

      // deassert 'ready' if (queue is full) && a pop isn't happening
      // or the queue is almost full and a push is happening and no pop is happening
      if ( ((q_count == ENTRIES[$bits(q_count)-1:0]) && !q_pop) || ((q_count == (ENTRIES[$bits(q_count)-1:0] - {{($bits(q_count)-1){1'b0}}, 1'b1})) && q_push && !q_pop) ) begin
        q_din.ready <= 1'b0;
      end else begin
        // only assert ready if enabled
        q_din.ready <= q_enable;
      end

    end // else: !if(rst_n == 1'b0)
  end // always @ (posedge clk or negedge rst_n)

  //input stage
  generate
  if(ENTRIES>1) begin : input_stage
    always @(posedge clk or negedge rst_n) begin
      // reset everything and clear the queue
      if (!rst_n) begin
        // initialize the queue
        input_q     <= DTYPE'('0);
        input_valid <= 1'b0;
      end else begin
        //update validity
        if(push_to_input) begin
          input_valid <= 1'b1;
        end else if(input_to_output || input_to_storage) begin
          input_valid <= 1'b0;
        end

        //push to input stage
        if(ALWAYS_PUSH_TO_INPUT) begin
          //better timing due to reduced fanout on q_dout.ready input signal
          //since q_dout.ready does not have to go to input_q
          if(q_push) begin
            input_q <= q_din.rv_payload;
          end
        end else begin
          //lower power consumption due to lower activity on input_q register
          if(push_to_input) begin
            input_q <= q_din.rv_payload;
          end
        end

      end
    end
  end else begin : no_input_stage
    //assign input_valid and input_q to constants
    //to handle degenerate case of 1 deep FIFO
    assign input_q = DTYPE'('0);
    assign input_valid = 1'b0;
  end

  if(ENTRIES>2) begin : storage_stage
    DTYPE storage_q [0:(ENTRIES-3)];
    pointer_t q_inptr_r, q_outptr_r;     // queue in/out pointers
    pointer_t q_inptr_incr, q_outptr_incr;

    // compute (inptr+1) and (outptr+1) once, use it any/many places
    assign q_inptr_incr  = (q_inptr_r == pLAST[$bits(q_inptr_r)-1:0])  ? '0 : q_inptr_r  + 1'b1;
    assign q_outptr_incr = (q_outptr_r == pLAST[$bits(q_outptr_r)-1:0]) ? '0 : q_outptr_r + 1'b1;

    always @(posedge clk or negedge rst_n) begin

      // reset everything and clear the queue
      if (rst_n == 1'b0) begin
        storage_q     <= '{default: DTYPE'('0)};
        storage_valid <= '0;
        // internal signals
        q_inptr_r    <= '0;
        q_outptr_r   <= '0;
      end else begin
        if (storage_to_output) begin
          //transfer from storage to output stage
          q_outptr_r <= q_outptr_incr;
          if(q_outptr_incr == q_inptr_r) storage_valid <= 1'b0;
        end

        //transfer from input stage to storage stage
        if (input_to_storage) begin
          //transfer from input stage to fifo storage
          storage_q[q_inptr_r] <= input_q;
          storage_valid <= 1'b1;
          q_inptr_r <= q_inptr_incr;
        end
      end // else: !if(rst_n == 1'b0)
    end // always @ (posedge clk or negedge rst_n)
    assign storage_out = storage_q[q_outptr_r];
  end else begin : no_storage_stage
    //assign storage_valid and storage_out to constants
    //to handle degenerate case of 2 deep FIFO
    assign storage_valid = 1'b0;
    assign storage_out = DTYPE'('0);
  end

  endgenerate

  //design assertions
`ifndef SYNTHESIS
`ifndef ASSERT_DISABLE
  iv_ov :    assert property (@(posedge clk) disable iff(!rst_n) input_valid -> output_valid)   else $error ("output_valid not set as expected");
  sv_ov :    assert property (@(posedge clk) disable iff(!rst_n) storage_valid -> output_valid) else $error ("output_valid not set as expected");
  count_ov : assert property (@(posedge clk) disable iff(!rst_n) output_valid == (q_count>0))   else $error ("output_valid not set as expected");
`endif
`endif

endmodule // vrqueue2

`default_nettype wire    // restore the default

// eof