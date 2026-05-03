//==============================================================================
// tb_tagged_sha256.v
//   tagged_hash(tag, x) = sha256(sha256(tag) || sha256(tag) || x)
//   tag_pre = sha256(tag) || sha256(tag)
//==============================================================================
`timescale 1ns/1ps

module tb_tagged_sha256;
    reg          clk = 0;
    reg          rst_n = 0;
    reg          start = 0;
    reg  [511:0] tag_pre;
    reg  [1023:0] data;
    reg  [11:0]  data_len;
    wire         done;
    wire [255:0] hash;

    tagged_sha256 dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .tag_pre(tag_pre),
        .data(data),
        .data_len(data_len),
        .done(done),
        .hash(hash)
    );

    always #5 clk = ~clk;

    // Test 1: tag="", data="abc"
    //   sha256("") = e3b0c442...7852b855
    localparam [255:0] T1_TAG_HASH =
        256'he3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;
    localparam [255:0] T1_EXP =
        256'hd7f526e0a2ee5577fc14454a6ccf01d91cd3d2b38915bd17706725e1ce6a0816;

    // Test 2: tag="BIP0340/aux", data=32 zero bytes
    localparam [255:0] T2_TAG_HASH =
        256'hf1ef4e5ec063cada6d94cafa9d987ea069265839ecc11f972d77a52ed8c1cc90;
    localparam [255:0] T2_EXP =
        256'h54f169cfc9e2e5727480441f90ba25c488f461c70b5ea5dcaaf7af69270aa514;

    // Test 3: tag="BIP0340/challenge", data=32 zero bytes
    localparam [255:0] T3_TAG_HASH =
        256'h7bb52d7a9fef58323eb1bf7a407db382d2f3f2d81bb1224f49fe518f6d48d37c;
    localparam [255:0] T3_EXP =
        256'ha50885aadef94ee57e5537e27ef82d4db7c756193539d3d8d0bb6ee5f3a7ad46;

    // Test 4: tag="BIP0340/nonce", data=96 bytes (32x 0x00 || 32x 0x11 || 32x 0x22)
    //   = total 160 byte → sha256_top 3-block path
    localparam [255:0] T4_TAG_HASH =
        256'h07497734a79bcb355b9b8c7d034f121cf434d73ef72dda19870061fb52bfeb2f;
    localparam [255:0] T4_EXP =
        256'h5c1ba54839ab901fbcf818b3e9b4659d4d23ea67ee62fbabf4a6fa684845cf0c;

    integer errors = 0;

    task run_tag;
        input [255:0]  th_v;        // sha256(tag)
        input [1023:0] data_v;
        input [11:0]   dl_v;
        input [255:0]  expected;
        input [127:0]  label;
        begin
            @(negedge clk);
            rst_n = 0; start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            tag_pre  = {th_v, th_v};
            data     = data_v;
            data_len = dl_v;
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

    reg [1023:0] dbuf;

    initial begin
        $dumpfile("tb_tagged_sha256.vcd");
        $dumpvars(0, tb_tagged_sha256);

        tag_pre = 0; data = 0; data_len = 0; start = 0;
        #20 rst_n = 1;
        #20;

        // Test 1: tag="", data="abc"
        dbuf = 0;
        dbuf[1023 -: 24] = 24'h616263;
        run_tag(T1_TAG_HASH, dbuf, 12'd3, T1_EXP, "tag_empty");

        // Test 2: tag="BIP0340/aux", data=32 zero bytes
        dbuf = 0;
        run_tag(T2_TAG_HASH, dbuf, 12'd32, T2_EXP, "BIP0340_aux");

        // Test 3: tag="BIP0340/challenge", data=32 zero bytes
        dbuf = 0;
        run_tag(T3_TAG_HASH, dbuf, 12'd32, T3_EXP, "BIP0340_chal");

        // Test 4: tag="BIP0340/nonce", data=96B (32x00 || 32x11 || 32x22)
        dbuf = 0;
        // 0x00 * 32 (上位 32B): すでに 0
        // 0x11 * 32 (次の 32B)
        begin : LOAD96
            integer k;
            for (k=0; k<32; k=k+1)
                dbuf[1023 - 32*8 - k*8 -: 8] = 8'h11;
            for (k=0; k<32; k=k+1)
                dbuf[1023 - 64*8 - k*8 -: 8] = 8'h22;
        end
        run_tag(T4_TAG_HASH, dbuf, 12'd96, T4_EXP, "BIP0340_nonce");

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
