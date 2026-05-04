`timescale 1ns/1ps
module tb_sub_check;
    reg [255:0] a, b;
    wire [255:0] r;
    field_sub_p u (.a(a), .b(b), .r(r));
    initial begin
        a = 256'h1F2565191BCD9EAD3489DD19A219125A0828B95782FED92F19163E6E89EF01C1;
        b = 256'h8550E7D238FCF3086BA9ADCF0FB52A9DE3652194D06CB5BB38D50229B854FC49;
        #1;
        $display("r        = %h", r);
        $display("expected = 99d47d46e2d0aba4c8e02f4a9263e7bc24c397c2b2922373e0413c43d19a01a7");
        $finish;
    end
endmodule
