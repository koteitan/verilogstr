//==============================================================================
// tb_sha256_top.v
//   sha256_top の任意長メッセージ + 自動パディングを検証
//   data は MAX_BYTES*8 ビット (デフォルト 1024) で、MSB側にメッセージを詰める。
//==============================================================================
`timescale 1ns/1ps

module tb_sha256_top;
    localparam MAX_BYTES = 128;
    reg          clk = 0;
    reg          rst_n = 0;
    reg          start = 0;
    reg  [MAX_BYTES*8-1:0] data;
    reg  [11:0]  data_len;
    reg  [255:0] h_init;
    wire         done;
    wire [255:0] hash;

    sha256_top #(.MAX_BYTES(MAX_BYTES)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .data(data), .data_len(data_len),
        .h_init(h_init),
        .done(done), .hash(hash)
    );

    always #5 clk = ~clk;

    localparam [255:0] IV =
        {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
         32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

    // 期待値
    localparam [255:0] EXP_ABC =
        {32'hba7816bf, 32'h8f01cfea, 32'h414140de, 32'h5dae2223,
         32'hb00361a3, 32'h96177a9c, 32'hb410ff61, 32'hf20015ad};
    localparam [255:0] EXP_EMPTY =
        {32'he3b0c442, 32'h98fc1c14, 32'h9afbf4c8, 32'h996fb924,
         32'h27ae41e4, 32'h649b934c, 32'ha495991b, 32'h7852b855};
    // FIPS 例 2: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" (56B → 2 ブロック)
    localparam [255:0] EXP_56 =
        {32'h248d6a61, 32'hd20638b8, 32'he5c02693, 32'h0c3e6039,
         32'ha33ce459, 32'h64ff2167, 32'hf6ecedd4, 32'h19db06c1};

    integer errors = 0;

    task run_top;
        input [MAX_BYTES*8-1:0] dat_v;
        input [11:0]            dl_v;
        input [255:0]           expected;
        input [127:0]           label;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            data     = dat_v;
            data_len = dl_v;
            h_init   = IV;
            start    = 1;
            @(negedge clk);
            start = 0;
            wait(done);
            @(negedge clk);
            if (hash === expected) begin
                $display("[PASS] %0s : %h", label, hash);
            end else begin
                $display("[FAIL] %0s", label);
                $display("       got = %h", hash);
                $display("       exp = %h", expected);
                errors = errors + 1;
            end
        end
    endtask

    integer i;
    reg [MAX_BYTES*8-1:0] dbuf;

    initial begin
        $dumpfile("tb_sha256_top.vcd");
        $dumpvars(0, tb_sha256_top);

        data = 0; data_len = 0; h_init = IV; start = 0;
        #20 rst_n = 1;
        #20;

        // --- "abc" (3 バイト, 1 ブロック) ---
        dbuf = 0;
        dbuf[MAX_BYTES*8-1 -: 24] = 24'h616263;
        run_top(dbuf, 12'd3, EXP_ABC, "abc");

        // --- 空文字列 (0 バイト) ---
        dbuf = 0;
        run_top(dbuf, 12'd0, EXP_EMPTY, "empty");

        // --- 56 バイト (2 ブロックパディング境界) ---
        // "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        dbuf = 0;
        begin : LOAD56
            reg [56*8-1:0] msg56;
            msg56 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
            // 56 バイト = 448 ビットを MSB 詰め
            dbuf[MAX_BYTES*8-1 -: 56*8] = msg56;
        end
        run_top(dbuf, 12'd56, EXP_56, "56B");

        if (errors == 0)
            $display("=== ALL TESTS PASSED ===");
        else
            $display("=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
