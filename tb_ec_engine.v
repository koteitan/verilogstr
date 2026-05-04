//==============================================================================
// tb_ec_engine.v
//   ec_engine (programmable EC engine) を ec_point_mul_g と同じ I/F で検証
//==============================================================================
`timescale 1ns/1ps

module tb_ec_engine;
    reg          clk = 0, rst_n = 0, start = 0;
    reg  [255:0] scalar;
    wire         done;
    wire [255:0] rx, ry;

    ec_engine dut (.clk(clk), .rst_n(rst_n), .start(start),
                   .scalar(scalar), .done(done), .rx(rx), .ry(ry));
    always #5 clk = ~clk;

    integer errors = 0;

    task run_mul;
        input [255:0] k;
        input [255:0] ex, ey;
        input [127:0] label;
        integer t0;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            scalar = k; start = 1;
            t0 = $time;
            @(negedge clk); start = 0;
            wait(done);
            @(negedge clk);
            $display("[DBG] %0s R5(PX)=%h", label, dut.regfile[5]);
            $display("[DBG] %0s R6(PY)=%h", label, dut.regfile[6]);
            $display("[DBG] %0s R7(PZ)=%h", label, dut.regfile[7]);
            $display("[DBG] %0s R13(DX_last)=%h", label, dut.regfile[13]);
            $display("[DBG] %0s R10(DY_last)=%h", label, dut.regfile[10]);
            $display("[DBG] %0s R14(DZ_last)=%h", label, dut.regfile[14]);
            if (rx === ex && ry === ey) begin
                $display("[PASS] %0s  (%0d cycles)", label, ($time - t0)/10);
            end else begin
                $display("[FAIL] %0s", label);
                $display("       got x=%h", rx);
                $display("       exp x=%h", ex);
                $display("       got y=%h", ry);
                $display("       exp y=%h", ey);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_ec_engine.vcd"); $dumpvars(0, tb_ec_engine);
        scalar = 0; start = 0;
        #20 rst_n = 1; #20;

        run_mul(256'd1,
                256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
                256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
                "1*G");
        run_mul(256'd2,
                256'hc6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5,
                256'h1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a,
                "2*G");
        run_mul(256'd3,
                256'hf9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9,
                256'h388f7b0f632de8140fe337e62a37f3566500a99934c2231b6cb9fd7584b8e672,
                "3*G");
        run_mul(256'd5,
                256'h2f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe4,
                256'hd8ac222636e5e3d6d4dba9dda6c9c426f788271bab0d6840dca87d3aa6ac62d6,
                "5*G");

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #500000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
