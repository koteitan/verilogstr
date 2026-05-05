//==============================================================================
// tb_seq_inv.v
//   field_seq_inv_p (sequential Fermat) を Python ベクタで検証
//==============================================================================
`timescale 1ns/1ps

module tb_seq_inv;
    reg          clk = 0, rst_n = 0, start = 0;
    reg  [255:0] a;
    wire         done;
    wire [255:0] r;

    field_seq_inv_p dut (.clk(clk), .rst_n(rst_n), .start(start),
                         .a(a), .done(done), .r(r));
    always #5 clk = ~clk;

    integer errors = 0;

    task run_inv;
        input [255:0] av, expected;
        input [127:0] label;
        integer t0;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            a = av; start = 1;
            t0 = $time;
            @(negedge clk); start = 0;
            wait(done);
            @(negedge clk);
            if (r === expected) begin
                $display("[PASS] %0s : %h (%0d cycles)", label, r, ($time-t0)/10);
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
        run_inv(256'd2,
                256'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffff7ffffe18,
                "inv 2");
        run_inv(256'd3,
                256'haaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa9fffffd75,
                "inv 3");
        run_inv(256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
                256'h237afdf1d2938d86870aaeb8ad77626a67b8e794abfb076be61d003687ca9ef6,
                "inv Gx");
        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    initial begin #500000000; $display("TIMEOUT"); $finish; end
endmodule
