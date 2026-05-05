//==============================================================================
// tb_mont.v
//   Montgomery 乗算器 (radix-2) を Python リファレンスで検証
//==============================================================================
`timescale 1ns/1ps

module tb_mont;
    reg          clk = 0, rst_n = 0, start = 0;
    reg  [255:0] a, b;
    wire         done;
    wire [255:0] r;

    field_mont_mul_p dut (.clk(clk), .rst_n(rst_n), .start(start),
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

        // 2 * 3 * R^-1 mod p
        run(256'd2, 256'd3,
            256'hba6e961e7ff51599a9a8908f83b04c4a6c2cd7f928dbc21b115036b23270a640,
            "MM(2,3)");

        // 0xdeadbeef * 0xcafebabe * R^-1 mod p
        run(256'h00000000000000000000000000000000000000000000000000000000deadbeef,
            256'h00000000000000000000000000000000000000000000000000000000cafebabe,
            256'h11cc9b6a1222e030c8e665d148b56c49839dbb70b307a6e4bfcc1100a4f92c14,
            "MM small");

        // GX * GY * R^-1 mod p
        run(256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
            256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
            256'hac8c2a517a504435fa970efa4296371caff3c5def0dc22d4a7b254f5aab574c8,
            "MM Gx*Gy");

        // Standard -> Mont:  MontMul(5, R^2) should = 5*R mod p = 0x...500001315
        run(256'd5,
            256'h000000000000000000000000000000000000000000000001000007a2000e90a1,
            256'h0000000000000000000000000000000000000000000000000000000500001315,
            "5 -> Mont");

        // Mont -> Standard:  MontMul(5_mont, 1) should = 5
        run(256'h0000000000000000000000000000000000000000000000000000000500001315,
            256'd1,
            256'd5,
            "Mont(5) -> 5");

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
