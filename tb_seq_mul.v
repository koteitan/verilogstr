//==============================================================================
// tb_seq_mul.v
//   field_seq_mul_p (sequential, drop-in for field_mul_p) の検証
//==============================================================================
`timescale 1ns/1ps

module tb_seq_mul;
    reg          clk = 0, rst_n = 0, start = 0;
    reg  [255:0] a, b;
    wire         done;
    wire [255:0] r;

    field_seq_mul_p dut (.clk(clk), .rst_n(rst_n), .start(start),
                         .a(a), .b(b), .done(done), .r(r));
    always #5 clk = ~clk;

    integer errors = 0;

    task run;
        input [255:0] av, bv, expected;
        input [127:0] label;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            a = av; b = bv; start = 1;
            @(negedge clk); start = 0;
            wait(done);
            @(negedge clk);
            if (r === expected) begin
                $display("[PASS] %0s : %h", label, r);
            end else begin
                $display("[FAIL] %0s", label);
                $display("       got = %h", r);
                $display("       exp = %h", expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #20 rst_n = 1; #20;

        // 同じテストベクタを field_mul_p と共有
        run(256'd2, 256'd3,
            256'h0000000000000000000000000000000000000000000000000000000000000006,
            "2*3");
        run(256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2E,
            256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2E,
            256'h0000000000000000000000000000000000000000000000000000000000000001,
            "(p-1)^2");
        run(256'h00000000000000000000000000000000000000000000000000000000deadbeef,
            256'h00000000000000000000000000000000000000000000000000000000cafebabe,
            256'h000000000000000000000000000000000000000000000000b092ab7b88cf5b62,
            "small");
        run(256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
            256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
            256'hfd3dc529c6eb60fb9d166034cf3c1a5a72324aa9dfd3428a56d7e1ce0179fd9b,
            "Gx*Gy");
        run(256'h0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,
            256'd1,
            256'h0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,
            "a*1");

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
