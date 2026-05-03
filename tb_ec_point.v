//==============================================================================
// tb_ec_point.v
//   Jacobian dbl/add + to_affine の単体テスト
//==============================================================================
`timescale 1ns/1ps

module tb_ec_point;
    localparam [255:0] GX =
        256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    localparam [255:0] GY =
        256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    // 2G
    localparam [255:0] G2X =
        256'hc6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5;
    localparam [255:0] G2Y =
        256'h1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a;
    // 3G
    localparam [255:0] G3X =
        256'hf9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9;
    localparam [255:0] G3Y =
        256'h388f7b0f632de8140fe337e62a37f3566500a99934c2231b6cb9fd7584b8e672;

    // 入力 Jacobian
    reg  [255:0] x1, y1, z1;
    reg  [255:0] x2, y2, z2;

    // dbl 出力
    wire [255:0] dx, dy, dz;
    ec_point_dbl_jac u_dbl (.x1(x1), .y1(y1), .z1(z1),
                            .x3(dx), .y3(dy), .z3(dz));

    // add 出力
    wire [255:0] ax, ay, az;
    ec_point_add_jac u_add (.x1(x1), .y1(y1), .z1(z1),
                            .x2(x2), .y2(y2), .z2(z2),
                            .x3(ax), .y3(ay), .z3(az));

    // to_affine
    reg          clk = 0, rst_n = 0, ta_start = 0;
    reg  [255:0] tax_in, tay_in, taz_in;
    wire         ta_done;
    wire [255:0] tax, tay;
    ec_to_affine u_aff (.clk(clk), .rst_n(rst_n), .start(ta_start),
                        .x_jac(tax_in), .y_jac(tay_in), .z_jac(taz_in),
                        .done(ta_done), .x_aff(tax), .y_aff(tay));
    always #5 clk = ~clk;

    integer errors = 0;

    task chk2;
        input [127:0] label;
        input [255:0] gx_, gy_;
        input [255:0] ex_, ey_;
        begin
            if (gx_ === ex_ && gy_ === ey_) begin
                $display("[PASS] %0s", label);
            end else begin
                $display("[FAIL] %0s", label);
                $display("       got x=%h y=%h", gx_, gy_);
                $display("       exp x=%h y=%h", ex_, ey_);
                errors = errors + 1;
            end
        end
    endtask

    // Jacobian to affine via the to_affine module (sequential)
    task affine_of;
        input [255:0] x_in, y_in, z_in;
        output [255:0] xa, ya;
        begin
            @(negedge clk);
            rst_n = 0; ta_start = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            tax_in = x_in; tay_in = y_in; taz_in = z_in;
            ta_start = 1;
            @(negedge clk); ta_start = 0;
            wait(ta_done);
            @(negedge clk);
            xa = tax; ya = tay;
        end
    endtask

    reg [255:0] xa_buf, ya_buf;

    initial begin
        $dumpfile("tb_ec_point.vcd"); $dumpvars(0, tb_ec_point);
        x1=0; y1=0; z1=0; x2=0; y2=0; z2=0;
        tax_in=0; tay_in=0; taz_in=0;
        #20 rst_n = 1; #20;

        // --- Test 1: dbl(G) → 2G ---
        x1 = GX; y1 = GY; z1 = 256'd1;
        #1;
        affine_of(dx, dy, dz, xa_buf, ya_buf);
        chk2("dbl(G)=2G", xa_buf, ya_buf, G2X, G2Y);

        // --- Test 2: add(G, 2G) → 3G ---
        // 2G as Jacobian (compute via dbl first)
        x1 = GX; y1 = GY; z1 = 256'd1;
        #1;
        // capture dbl output as input to add
        begin : ADD_TEST
            reg [255:0] tx, ty, tz;
            tx = dx; ty = dy; tz = dz;
            // x1 stays G, x2 = 2G (Jacobian)
            x2 = tx; y2 = ty; z2 = tz;
            #1;
            affine_of(ax, ay, az, xa_buf, ya_buf);
            chk2("add(G,2G)=3G", xa_buf, ya_buf, G3X, G3Y);
        end

        // --- Test 3: add(O, G) = G ---
        x1 = 0; y1 = 0; z1 = 0;          // O
        x2 = GX; y2 = GY; z2 = 256'd1;
        #1;
        // Z3 should be 1 (=z2), affine = G
        affine_of(ax, ay, az, xa_buf, ya_buf);
        chk2("add(O,G)=G", xa_buf, ya_buf, GX, GY);

        // --- Test 4: add(G, O) = G ---
        x1 = GX; y1 = GY; z1 = 256'd1;
        x2 = 0; y2 = 0; z2 = 0;
        #1;
        affine_of(ax, ay, az, xa_buf, ya_buf);
        chk2("add(G,O)=G", xa_buf, ya_buf, GX, GY);

        // --- Test 5: dbl(O) = O ---
        x1 = 0; y1 = 0; z1 = 0;
        #1;
        if (dz === 256'd0)
            $display("[PASS] dbl(O)=O (z=0)");
        else begin
            $display("[FAIL] dbl(O) z=%h", dz);
            errors = errors + 1;
        end

        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #100000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
