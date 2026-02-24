function automatic [7:0] sat_add8_2b(input [7:0] a, input [1:0] b);
    reg [8:0] s;
    begin
        s = {1'b0, a} + {7'b0, b};
        sat_add8_2b = s[8] ? 8'hFF : s[7:0];
    end
endfunction

function automatic [7:0] leak8(input [7:0] v, input [2:0] sh);
    reg [7:0] dec;
    begin
        dec = (sh == 0) ? v : (v >> sh);
        leak8 = v - dec;
    end
endfunction

function automatic [1:0] sat_inc2(input [1:0] x);
    begin
        sat_inc2 = (x == 2'b11) ? 2'b11 : (x + 2'b01);
    end
endfunction

function automatic [1:0] sat_dec2(input [1:0] x);
    begin
        sat_dec2 = (x == 2'b00) ? 2'b00 : (x - 2'b01);
    end
endfunction
