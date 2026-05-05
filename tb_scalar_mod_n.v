//==============================================================================
// tb_scalar_mod_n.v
//   sequential 化した scalar_mod_n (add/sub/mul mod n) を Python ベクタで検証
//==============================================================================
`timescale 1ns/1ps

module tb_scalar_mod_n;
    reg          clk = 0, rst_n = 0, start = 0;
    reg  [1:0]   op;
    reg  [255:0] a, b;
    wire         done;
    wire [255:0] result;

    scalar_mod_n dut (.clk(clk), .rst_n(rst_n), .start(start),
                      .op(op), .a(a), .b(b),
                      .done(done), .result(result));
    always #5 clk = ~clk;

    integer errors = 0;

    task run;
        input [1:0]   op_v;
        input [255:0] av, bv, expected;
        input [127:0] label;
        integer t0;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            op = op_v; a = av; b = bv; start = 1;
            t0 = $time;
            @(negedge clk); start = 0;
            wait(done);
            @(negedge clk);
            if (result === expected) begin
                $display("[PASS] %0s : %h (%0d cyc)", label, result, ($time-t0)/10);
            end else begin
                $display("[FAIL] %0s", label);
                $display("       got = %h", result);
                $display("       exp = %h", expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #20 rst_n = 1; #20;

        // add
        run(2'd0, 256'd1, 256'd1, 256'd2, "add 1+1");
        run(2'd0,
            256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140,
            256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140,
            256'hfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd036413f,
            "add (n-1)*2");

        // sub
        run(2'd1, 256'd0, 256'd1,
            256'hfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140,
            "sub 0-1");

        // mul
        run(2'd2, 256'd2, 256'd3, 256'd6, "mul 2*3");
        run(2'd2,
            256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140,
            256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140,
            256'h1,
            "mul (n-1)^2");
        run(2'd2,
            256'h00000000000000000000000000000000000000000000000000000000deadbeef,
            256'h00000000000000000000000000000000000000000000000000000000cafebabe,
            256'h000000000000000000000000000000000000000000000000b092ab7b88cf5b62,
            "mul small");
        run(2'd2,
            256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
            256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
            256'h805714a252d0c0b58910907e85b5b801fff610a36bdf46847a4bf5d9ae2d10ed,
            "mul Gx*Gy");

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
