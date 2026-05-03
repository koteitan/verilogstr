//==============================================================================
// tb_nostr_sign.v
//   - 動作確認用テストベンチ
//   - 実際の署名値検証はソフトウェア側 (例: noble-secp256k1) と突き合わせる想定
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

    initial begin
        $dumpfile("nostr_sign.vcd");
        $dumpvars(0, tb_nostr_sign);

        // BIP-340 のテストベクタ (Nostr の典型値ではないが、Schnorr テスト用)
        sec_key  = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        msg      = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        aux_rand = 256'h0000000000000000000000000000000000000000000000000000000000000000;

        #20 rst_n = 1;
        #20 start = 1;
        #10 start = 0;

        // 完了待ち (スタブ実装の遅延を考慮して長めに)
        wait(done);
        $display("=== Nostr Sign Done ===");
        $display("err   = %b", err);
        $display("sig_r = %h", sig_r);
        $display("sig_s = %h", sig_s);

        #100 $finish;
    end

    // 暴走保護
    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
