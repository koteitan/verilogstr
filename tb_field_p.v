//==============================================================================
// tb_field_p.v
//   secp256k1 mod p 算術 (field_add_p / field_sub_p / field_mul_p) のテスト
//==============================================================================
`timescale 1ns/1ps

module tb_field_p;
    localparam [255:0] P =
        256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    reg  [255:0] a, b;
    wire [255:0] r_add, r_sub, r_mul;

    field_add_p u_add (.a(a), .b(b), .r(r_add));
    field_sub_p u_sub (.a(a), .b(b), .r(r_sub));
    field_mul_p u_mul (.a(a), .b(b), .r(r_mul));

    integer errors = 0;

    task chk;
        input [127:0] label;
        input [255:0] got;
        input [255:0] expected;
        begin
            if (got === expected) begin
                $display("[PASS] %0s : %h", label, got);
            end else begin
                $display("[FAIL] %0s", label);
                $display("       got = %h", got);
                $display("       exp = %h", expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Add
        a = 1; b = 1; #1;
        chk("add 1+1", r_add, 256'h2);
        a = P - 1; b = P - 1; #1;
        chk("add p-1 twice", r_add,
            256'hfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2d);
        a = 0; b = 0; #1;
        chk("add 0+0", r_add, 256'h0);

        // Sub
        a = 0; b = 1; #1;
        chk("sub 0-1", r_sub,
            256'hfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2e);
        a = 5; b = 3; #1;
        chk("sub 5-3", r_sub, 256'h2);
        a = P - 1; b = P - 1; #1;
        chk("sub eq", r_sub, 256'h0);

        // Mul
        a = 2; b = 3; #1;
        chk("mul 2*3", r_mul, 256'h6);
        a = P - 1; b = P - 1; #1;
        chk("mul (p-1)^2", r_mul, 256'h1);
        a = 256'hdeadbeef; b = 256'hcafebabe; #1;
        chk("mul small", r_mul, 256'hb092ab7b88cf5b62);
        a = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
        b = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
        #1;
        chk("mul Gx*Gy", r_mul,
            256'hfd3dc529c6eb60fb9d166034cf3c1a5a72324aa9dfd3428a56d7e1ce0179fd9b);

        // Edge: a*1 = a
        a = 256'h0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;
        b = 1; #1;
        chk("mul a*1", r_mul,
            256'h0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef);

        if (errors == 0)
            $display("=== ALL TESTS PASSED ===");
        else
            $display("=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end
endmodule
