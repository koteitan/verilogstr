//==============================================================================
// tb_hello_world.v
//   適当な nsec1 で kind:1 / content:"hello world" を Verilog 上で署名
//   sk         = b0bf8a3e6b4c0d31a5e2f0f54f0a1238c7e8a32f5d99e3146a5ad12bbf4a1c93
//   nsec1      = nsec1kzlc50ntfsxnrf0z7r657zsj8rr73ge0tkv7x9r2ttgjh062rjfs5hqm5t
//   pubkey(x)  = a9b83938236f15c452ff53c0ebde24f6b52f9ae9ca478218c4ecbc67c0c21420
//   created_at = 1700000000
//   event_id   = 871ce455cfdbaf3deb04a8f101494df9142fc1f9eeba8fc6d0934768f4063062
//==============================================================================
`timescale 1ns/1ps

module tb_hello_world;
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

    always #5 clk = ~clk;

    initial begin
        $dumpfile("tb_hello_world.vcd"); $dumpvars(0, tb_hello_world);
        sec_key = 0; aux_rand = 0; msg = 0; start = 0;
        #20 rst_n = 1; #20;

        sec_key  = 256'hb0bf8a3e6b4c0d31a5e2f0f54f0a1238c7e8a32f5d99e3146a5ad12bbf4a1c93;
        aux_rand = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        msg      = 256'h871ce455cfdbaf3deb04a8f101494df9142fc1f9eeba8fc6d0934768f4063062;

        @(negedge clk);
        start = 1;
        begin : MEASURE
            integer t_start;
            t_start = $time;
            @(negedge clk);
            start = 0;
            wait(done);
            @(negedge clk);
            if (err) begin
                $display("=== ERROR (err=1) ===");
            end else begin
                $display("=== Verilog signed: ===");
                $display("R = %h", sig_r);
                $display("s = %h", sig_s);
                $display("sig (R||s) = %h%h", sig_r, sig_s);
                // 1 cycle = 10ns (clk #5)
                $display("[CYCLES] start->done = %0d cycles (%0d ns)",
                         ($time - t_start)/10, $time - t_start);
            end
        end

        #100 $finish;
    end

    initial begin
        #500000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
