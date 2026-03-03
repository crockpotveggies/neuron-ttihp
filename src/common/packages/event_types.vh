localparam [1:0] CMD_CSR    = 2'b00;
localparam [1:0] CMD_WEIGHT = 2'b01;
localparam [1:0] CMD_UCODE  = 2'b10;
localparam [1:0] CMD_EVENT  = 2'b11;

localparam [1:0] TERN_ZERO = 2'b00;
localparam [1:0] TERN_POS  = 2'b01;
localparam [1:0] TERN_NEG  = 2'b11;

localparam [4:0] OP_LDI         = 5'd0;
localparam [4:0] OP_RECV        = 5'd1;
localparam [4:0] OP_ACCUM_W     = 5'd2;
localparam [4:0] OP_LEAK        = 5'd3;
localparam [4:0] OP_INTEG       = 5'd4;
localparam [4:0] OP_SPIKE_IF_GE = 5'd5;
localparam [4:0] OP_RESET       = 5'd6;
localparam [4:0] OP_REFRACT     = 5'd7;
localparam [4:0] OP_EMIT        = 5'd8;
localparam [4:0] OP_TDEC        = 5'd9;
localparam [4:0] OP_TINC        = 5'd10;
localparam [4:0] OP_STDP_LITE   = 5'd11;
