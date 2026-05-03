//==============================================================================
// tb_sha256_block.v
//   FIPS 180-4 公式テストベクタ "abc" で sha256_block を検証
//   "abc" = 0x61 0x62 0x63 (3 バイト)
//   1 ブロック (パディング込み):
//     W[0]  = 0x61626380
//     W[1..14] = 0
//     W[15] = 0x00000018  (24 bit メッセージ長)
//   期待値:
//     ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad
//==============================================================================
`timescale 1ns/1ps

module tb_sha256_block;
    reg          clk = 0;
    reg          rst_n = 0;
    reg          start = 0;
    reg  [255:0] h_in;
    reg  [511:0] block;
    wire         done;
    wire [255:0] h_out;

    sha256_block dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .h_in(h_in), .block(block),
        .done(done), .h_out(h_out)
    );

    always #5 clk = ~clk;

    // SHA-256 初期ハッシュ値 H0..H7
    localparam [255:0] IV =
        {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
         32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

    localparam [255:0] EXP_ABC =
        {32'hba7816bf, 32'h8f01cfea, 32'h414140de, 32'h5dae2223,
         32'hb00361a3, 32'h96177a9c, 32'hb410ff61, 32'hf20015ad};

    // 空文字列 "" の期待値:
    //   block = 0x80 || 0..0 (length=0)
    //   期待: e3b0c442 98fc1c14 9afbf4c8 996fb924 27ae41e4 649b934c a495991b 7852b855
    localparam [511:0] BLOCK_EMPTY =
        {32'h80000000, {14{32'h0}}, 32'h00000000};
    localparam [255:0] EXP_EMPTY =
        {32'he3b0c442, 32'h98fc1c14, 32'h9afbf4c8, 32'h996fb924,
         32'h27ae41e4, 32'h649b934c, 32'ha495991b, 32'h7852b855};

    integer errors = 0;

    task run_block;
        input [255:0] hin_v;
        input [511:0] blk_v;
        input [255:0] expected;
        input [127:0] label;
        begin
            // 各ラン前にリセット
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            h_in  = hin_v;
            block = blk_v;
            start = 1;
            @(negedge clk);
            start = 0;
            wait(done);
            @(negedge clk);
            if (h_out === expected) begin
                $display("[PASS] %0s : %h", label, h_out);
            end else begin
                $display("[FAIL] %0s", label);
                $display("       got = %h", h_out);
                $display("       exp = %h", expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_sha256_block.vcd");
        $dumpvars(0, tb_sha256_block);

        h_in  = 0;
        block = 0;
        start = 0;
        #20 rst_n = 1;
        #20;

        // テスト 1: "abc"
        begin : T_ABC
            reg [511:0] blk;
            blk = 512'h0;
            blk[511:480] = 32'h61626380;  // W[0]
            blk[31:0]    = 32'h00000018;  // W[15] = 24 bit
            run_block(IV, blk, EXP_ABC, "abc");
        end

        // テスト 2: 空文字列 ""
        run_block(IV, BLOCK_EMPTY, EXP_EMPTY, "empty");

        if (errors == 0)
            $display("=== ALL TESTS PASSED ===");
        else
            $display("=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    // 暴走保護
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
