//==============================================================================
// tb_field_inv.v
//   field_inv_p (Fermat 法による逆元) のテスト
//==============================================================================
`timescale 1ns/1ps

module tb_field_inv;
    reg          clk = 0;
    reg          rst_n = 0;
    reg          start = 0;
    reg  [255:0] a;
    wire         done;
    wire [255:0] r;

    field_inv_p dut (.clk(clk), .rst_n(rst_n), .start(start), .a(a), .done(done), .r(r));
    always #5 clk = ~clk;

    integer errors = 0;

    task run_inv;
        input [255:0] a_v;
        input [255:0] expected;
        input [127:0] label;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            a = a_v; start = 1;
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
        $dumpfile("tb_field_inv.vcd"); $dumpvars(0, tb_field_inv);
        a = 0; start = 0;
        #20 rst_n = 1; #20;

        run_inv(256'd2,
                256'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffff7ffffe18,
                "inv 2");
        run_inv(256'd3,
                256'haaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa9fffffd75,
                "inv 3");
        run_inv(256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
                256'h237afdf1d2938d86870aaeb8ad77626a67b8e794abfb076be61d003687ca9ef6,
                "inv Gx");
        run_inv(256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2E,
                256'hfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2e,
                "inv p-1");

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
