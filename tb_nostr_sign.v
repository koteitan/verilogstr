//==============================================================================
// tb_nostr_sign.v
//   BIP-340 公式テストベクタで Nostr (Schnorr) 署名のビット完全一致を検証
//==============================================================================

`timescale 1ns/1ps

module tb_nostr_sign;
    reg          clk = 0;
    reg          rst_n = 0;
    reg          start = 0;
    reg  [255:0] msg, sec_key, aux_rand;
    wire         done, err;
    wire [255:0] sig_r, sig_s;

    nostr_sign dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .msg(msg), .sec_key(sec_key), .aux_rand(aux_rand),
        .done(done), .err(err),
        .sig_r(sig_r), .sig_s(sig_s)
    );

    always #5 clk = ~clk;  // 100MHz

    integer errors = 0;

    task run_sign;
        input [255:0] sk_v, aux_v, msg_v;
        input [255:0] exp_r, exp_s;
        input [127:0] label;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            sec_key  = sk_v;
            aux_rand = aux_v;
            msg      = msg_v;
            start    = 1;
            @(negedge clk); start = 0;
            wait(done);
            @(negedge clk);
            if (err === 1'b0 && sig_r === exp_r && sig_s === exp_s) begin
                $display("[PASS] %0s", label);
            end else begin
                $display("[FAIL] %0s err=%b", label, err);
                $display("       got R=%h", sig_r);
                $display("       exp R=%h", exp_r);
                $display("       got s=%h", sig_s);
                $display("       exp s=%h", exp_s);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("nostr_sign.vcd");
        $dumpvars(0, tb_nostr_sign);
        sec_key = 0; aux_rand = 0; msg = 0; start = 0;
        #20 rst_n = 1; #20;

        // BIP-340 vector 0
        run_sign(
            256'h0000000000000000000000000000000000000000000000000000000000000003,
            256'h0000000000000000000000000000000000000000000000000000000000000000,
            256'h0000000000000000000000000000000000000000000000000000000000000000,
            256'hE907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215,
            256'h25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0,
            "v00");

        // BIP-340 vector 1
        run_sign(
            256'hB7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF,
            256'h0000000000000000000000000000000000000000000000000000000000000001,
            256'h243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89,
            256'h6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341,
            256'h8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A,
            "v01");

        // BIP-340 vector 2
        run_sign(
            256'hC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9,
            256'hC87AA53824B4D7AE2EB035A2B5BBBCCC080E76CDC6D1692C4B0B62D798E6D906,
            256'h7E2D58D8B3BCDF1ABADEC7829054F90DDA9805AAB56C77333024B9D0A508B75C,
            256'h5831AAEED7B44BB74E5EAB94BA9D4294C49BCF2A60728D8B4C200F50DD313C1B,
            256'hAB745879A5AD954A72C45A91C3A51D3C7ADEA98D82F8481E0E1E03674A6F3FB7,
            "v02");

        // BIP-340 vector 3 (max aux/msg, both 0xFF*32)
        run_sign(
            256'h0B432B2677937381AEF05BB02A66ECD012773062CF3FA2549E44F58ED2401710,
            256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
            256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
            256'h7EB0509757E246F19449885651611CB965ECC1A187DD51B64FDA1EDC9637D5EC,
            256'h97582B9CB13DB3933705B32BA982AF5AF25FD78881EBB32771FC5922EFC66EA3,
            "v03");

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);

        #100 $finish;
    end

    initial begin
        #1000000000;        // 1G ns = 100M cycles, 4 sigs in constant-time mode
        $display("TIMEOUT");
        $finish;
    end
endmodule
