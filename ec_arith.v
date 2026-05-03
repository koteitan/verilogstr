//==============================================================================
// ec_arith.v
//
// secp256k1 の楕円曲線演算 — インターフェースとシミュレーション用スタブ実装
//
// 重要:
//   合成して実機で動かすには、以下を本格実装に差し替える必要がある:
//     - field_add_p / field_sub_p / field_mul_p (mod p, p=2^256-2^32-977)
//       → 通常 Montgomery 乗算器で実装。1 mul あたり数十〜数百サイクル。
//     - 点加算 / 点二倍 (Jacobian 座標で実装するのが定石)
//     - スカラー倍 (Double-and-add ＋ サイドチャネル対策)
//
//   ここでは「ステートマシンと外部 I/F の検証」を目的とした
//   サイクル消費型のダミー (固定値返し) として書く。
//==============================================================================

`timescale 1ns/1ps

//==============================================================================
// secp256k1 mod p フィールド演算 (combinational)
//   p = 2^256 - 2^32 - 977
//   c = 2^256 - p = 2^32 + 977 = 0x1_0000_03D1
//   2^256 ≡ c (mod p) を使った高速 reduction を 2 段で実施
//==============================================================================
module field_add_p (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire [255:0] r
);
    localparam [255:0] P =
        256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    wire [256:0] s = {1'b0, a} + {1'b0, b};
    assign r = (s >= {1'b0, P}) ? (s - {1'b0, P}) : s[255:0];
endmodule

module field_sub_p (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire [255:0] r
);
    localparam [255:0] P =
        256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    wire [256:0] d = {1'b0, a} - {1'b0, b};   // 借りが出れば最上位ビットが 1
    assign r = d[256] ? (d + {1'b0, P}) : d[255:0];
endmodule

module field_mul_p (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire [255:0] r
);
    localparam [255:0] P =
        256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    localparam [256:0] P2 = {P, 1'b0};

    // 256x256 → 512 bit
    wire [511:0] z  = a * b;
    wire [255:0] zh = z[511:256];
    wire [255:0] zl = z[255:0];

    // 1段目: t1 = zl + zh * (2^32 + 977)
    wire [266:0] m977_zh   = 977 * zh;        // 277 ビット程度に収まる
    wire [288:0] zh_shl32  = {zh, 32'h0};
    wire [289:0] zh_c      = {1'b0, zh_shl32} + {22'h0, m977_zh};
    wire [290:0] t1        = {1'b0, zh_c} + {34'h0, zl};

    wire [34:0]  t1h = t1[290:256];
    wire [255:0] t1l = t1[255:0];

    // 2段目: t2 = t1l + t1h * c
    wire [44:0]  m977_t1h  = 977 * t1h;
    wire [66:0]  t1h_shl32 = {t1h, 32'h0};
    wire [67:0]  t1h_c     = {1'b0, t1h_shl32} + {22'h0, m977_t1h};
    wire [256:0] t2        = {1'b0, t1l} + {189'h0, t1h_c};

    // 最終調整 (t2 < 3p なので最大 2p の引き算)
    wire [256:0] t2_m_p  = t2 - {1'b0, P};
    wire [256:0] t2_m_2p = t2 - P2;
    assign r = (t2 >= P2)         ? t2_m_2p[255:0] :
               (t2 >= {1'b0, P})  ? t2_m_p[255:0]  :
                                    t2[255:0];
endmodule


//------------------------------------------------------------------------------
// 逆元 a^{-1} mod p を Fermat の小定理 (a^(p-2) mod p) で計算
//   exp = p - 2 (256 ビット LSB-first で見て square-and-multiply)
//   1 サイクル 1 反復: result = result * (a の累乗)、base = base^2
//   ~257 サイクルで完了
//------------------------------------------------------------------------------
module field_inv_p (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] a,
    output reg          done,
    output reg  [255:0] r
);
    localparam [255:0] EXP =
        256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D;

    reg  [255:0] base, result;
    reg  [8:0]   i;
    reg          active;

    wire [255:0] base_sq, mul_res;
    field_mul_p u_sq  (.a(base),   .b(base), .r(base_sq));
    field_mul_p u_mul (.a(result), .b(base), .r(mul_res));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; done <= 0; i <= 0;
            base <= 0; result <= 0; r <= 0;
        end else begin
            done <= 0;
            if (start && !active) begin
                base   <= a;
                result <= 256'd1;
                i      <= 0;
                active <= 1;
            end else if (active) begin
                if (i < 9'd256) begin
                    if (EXP[i[7:0]]) result <= mul_res;
                    base <= base_sq;
                    i    <= i + 1;
                end else begin
                    r      <= result;
                    done   <= 1;
                    active <= 0;
                end
            end
        end
    end
endmodule


//------------------------------------------------------------------------------
// 点二倍 (Jacobian, a=0, secp256k1 用)
//   入力:  (x1,y1,z1)、出力: (x3,y3,z3) = 2*(x1,y1,z1)
//   z1=0 (無限遠点) のとき z3=0 で伝播
//   formula: dbl-2009-l (a=0)
//------------------------------------------------------------------------------
module ec_point_dbl_jac (
    input  wire [255:0] x1, y1, z1,
    output wire [255:0] x3, y3, z3
);
    wire [255:0] A, B, C;
    wire [255:0] X1pB, X1pB_sq, T1, T2, D;
    wire [255:0] twoA, E, F;
    wire [255:0] twoD;
    wire [255:0] DmX3, EDX3;
    wire [255:0] twoC, fourC, eightC;
    wire [255:0] Y1Z1;

    field_mul_p mA  (.a(x1), .b(x1), .r(A));        // A = X1^2
    field_mul_p mB  (.a(y1), .b(y1), .r(B));        // B = Y1^2
    field_mul_p mC  (.a(B),  .b(B),  .r(C));        // C = B^2

    field_add_p aXB    (.a(x1),     .b(B),     .r(X1pB));
    field_mul_p mXB_sq (.a(X1pB),   .b(X1pB),  .r(X1pB_sq));
    field_sub_p sT1    (.a(X1pB_sq),.b(A),     .r(T1));
    field_sub_p sT2    (.a(T1),     .b(C),     .r(T2));
    field_add_p aD     (.a(T2),     .b(T2),    .r(D));    // D = 2*((X1+B)^2 - A - C)

    field_add_p a2A    (.a(A),      .b(A),     .r(twoA));
    field_add_p aE     (.a(twoA),   .b(A),     .r(E));    // E = 3*A

    field_mul_p mF     (.a(E),      .b(E),     .r(F));    // F = E^2

    field_add_p a2D    (.a(D),      .b(D),     .r(twoD));
    field_sub_p sX3    (.a(F),      .b(twoD),  .r(x3));   // X3 = F - 2D

    field_add_p a2C    (.a(C),      .b(C),     .r(twoC));
    field_add_p a4C    (.a(twoC),   .b(twoC),  .r(fourC));
    field_add_p a8C    (.a(fourC),  .b(fourC), .r(eightC));

    field_sub_p sDmX3  (.a(D),      .b(x3),    .r(DmX3));
    field_mul_p mEDX3  (.a(E),      .b(DmX3),  .r(EDX3));
    field_sub_p sY3    (.a(EDX3),   .b(eightC),.r(y3));   // Y3 = E*(D - X3) - 8C

    field_mul_p mY1Z1  (.a(y1),     .b(z1),    .r(Y1Z1));
    field_add_p aZ3    (.a(Y1Z1),   .b(Y1Z1),  .r(z3));   // Z3 = 2*Y1*Z1
endmodule


//------------------------------------------------------------------------------
// 点加算 (Jacobian, a=0)
//   入力: (x1,y1,z1) + (x2,y2,z2)
//   特殊ケース:
//     - Z1=0: 結果 = P2
//     - Z2=0: 結果 = P1
//     - それ以外で H=0,r=0 (P1=P2): 二倍が必要 (本実装ではエラー伝播)
//     - H=0,r≠0 (P1=-P2): Z3=0 (無限遠点)
//   formula: add-2007-bl (Jacobian)
//------------------------------------------------------------------------------
module ec_point_add_jac (
    input  wire [255:0] x1, y1, z1,
    input  wire [255:0] x2, y2, z2,
    output wire [255:0] x3, y3, z3
);
    wire [255:0] z1sq, z2sq, z1cb, z2cb;
    wire [255:0] U1, U2, S1, S2;
    wire [255:0] H, twoH, H4, J, S2mS1, r;
    wire [255:0] V;
    wire [255:0] r_sq, twoV, X3_a, X3_gen;
    wire [255:0] VmX3, rVmX3, S1J, twoS1J, Y3_gen;
    wire [255:0] Z1Z2, twoZ1Z2, Z3_gen;

    field_mul_p mZ1sq (.a(z1),   .b(z1),   .r(z1sq));
    field_mul_p mZ2sq (.a(z2),   .b(z2),   .r(z2sq));
    field_mul_p mZ1cb (.a(z1sq), .b(z1),   .r(z1cb));
    field_mul_p mZ2cb (.a(z2sq), .b(z2),   .r(z2cb));

    field_mul_p mU1 (.a(x1), .b(z2sq), .r(U1));
    field_mul_p mU2 (.a(x2), .b(z1sq), .r(U2));
    field_mul_p mS1 (.a(y1), .b(z2cb), .r(S1));
    field_mul_p mS2 (.a(y2), .b(z1cb), .r(S2));

    field_sub_p sH      (.a(U2), .b(U1), .r(H));
    field_sub_p sS2mS1  (.a(S2), .b(S1), .r(S2mS1));
    field_add_p ar      (.a(S2mS1), .b(S2mS1), .r(r));     // r = 2*(S2-S1)

    field_add_p atwoH (.a(H), .b(H), .r(twoH));
    field_mul_p mI    (.a(twoH), .b(twoH), .r(H4));         // I = (2H)^2
    field_mul_p mJ    (.a(H), .b(H4), .r(J));               // J = H * I
    field_mul_p mV    (.a(U1), .b(H4), .r(V));              // V = U1 * I

    field_mul_p mr_sq (.a(r), .b(r), .r(r_sq));
    field_add_p atwoV (.a(V), .b(V), .r(twoV));
    field_sub_p sX3a  (.a(r_sq), .b(J), .r(X3_a));
    field_sub_p sX3   (.a(X3_a), .b(twoV), .r(X3_gen));     // X3 = r^2 - J - 2V

    field_sub_p sVmX3   (.a(V), .b(X3_gen), .r(VmX3));
    field_mul_p mrVmX3  (.a(r), .b(VmX3), .r(rVmX3));
    field_mul_p mS1J    (.a(S1), .b(J), .r(S1J));
    field_add_p atwoS1J (.a(S1J), .b(S1J), .r(twoS1J));
    field_sub_p sY3     (.a(rVmX3), .b(twoS1J), .r(Y3_gen));// Y3 = r*(V-X3) - 2*S1*J

    field_mul_p mZ1Z2    (.a(z1), .b(z2), .r(Z1Z2));
    field_add_p atwoZ1Z2 (.a(Z1Z2), .b(Z1Z2), .r(twoZ1Z2));
    field_mul_p mZ3      (.a(twoZ1Z2), .b(H), .r(Z3_gen));  // Z3 = 2*Z1*Z2*H

    wire z1_zero = (z1 == 256'd0);
    wire z2_zero = (z2 == 256'd0);

    assign x3 = z1_zero ? x2 : (z2_zero ? x1 : X3_gen);
    assign y3 = z1_zero ? y2 : (z2_zero ? y1 : Y3_gen);
    assign z3 = z1_zero ? z2 : (z2_zero ? z1 : Z3_gen);
endmodule


//------------------------------------------------------------------------------
// Jacobian → Affine 変換
//   x_aff = X / Z^2,  y_aff = Y / Z^3
//   Z=0 のとき (0,0) を返す (実用上は無限遠点のフラグ別途)
//------------------------------------------------------------------------------
module ec_to_affine (
    input  wire         clk, rst_n,
    input  wire         start,
    input  wire [255:0] x_jac, y_jac, z_jac,
    output reg          done,
    output reg  [255:0] x_aff, y_aff
);
    reg          inv_start;
    wire         inv_done;
    wire [255:0] z_inv;

    field_inv_p u_inv (.clk(clk), .rst_n(rst_n), .start(inv_start),
                       .a(z_jac), .done(inv_done), .r(z_inv));

    wire [255:0] z_inv_sq, z_inv_cb;
    wire [255:0] x_aff_w, y_aff_w;
    field_mul_p msq (.a(z_inv),    .b(z_inv), .r(z_inv_sq));
    field_mul_p mcb (.a(z_inv_sq), .b(z_inv), .r(z_inv_cb));
    field_mul_p mxa (.a(x_jac),    .b(z_inv_sq), .r(x_aff_w));
    field_mul_p mya (.a(y_jac),    .b(z_inv_cb), .r(y_aff_w));

    reg [1:0] st;
    localparam ST_IDLE=0, ST_INV=1, ST_FINISH=2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; done <= 0; inv_start <= 0;
            x_aff <= 0; y_aff <= 0;
        end else begin
            inv_start <= 0;
            done      <= 0;
            case (st)
            ST_IDLE: if (start) begin
                if (z_jac == 256'd0) begin
                    x_aff <= 0; y_aff <= 0; done <= 1; st <= ST_IDLE;
                end else begin
                    inv_start <= 1;
                    st        <= ST_INV;
                end
            end
            ST_INV: if (inv_done) begin
                x_aff <= x_aff_w;
                y_aff <= y_aff_w;
                done  <= 1;
                st    <= ST_IDLE;
            end
            default: st <= ST_IDLE;
            endcase
        end
    end
endmodule


//------------------------------------------------------------------------------
// k * G を計算 (G = secp256k1 のジェネレータ)
//------------------------------------------------------------------------------
module ec_point_mul_g (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] scalar,
    output reg          done,
    output reg  [255:0] rx,
    output reg  [255:0] ry
);
    // secp256k1 ジェネレータ G
    localparam [255:0] GX =
        256'h79BE667E_F9DCBBAC_55A06295_CE870B07_029BFCDB_2DCE28D9_59F2815B_16F81798;
    localparam [255:0] GY =
        256'h483ADA77_26A3C465_5DA4FBFC_0E1108A8_FD17B448_A6855419_9C47D08F_FB10D4B8;

    // Jacobian P = (Px,Py,Pz)
    reg  [255:0] Px, Py, Pz;
    reg  [255:0] k_reg;
    reg  [8:0]   i;
    reg  [1:0]   st;
    localparam ST_IDLE=0, ST_LOOP=1, ST_AFF_WAIT=2;

    // dbl(P)
    wire [255:0] dx, dy, dz;
    ec_point_dbl_jac u_dbl (.x1(Px), .y1(Py), .z1(Pz),
                            .x3(dx), .y3(dy), .z3(dz));

    // add(dbl(P), G)
    wire [255:0] ax, ay, az;
    ec_point_add_jac u_add (.x1(dx), .y1(dy), .z1(dz),
                            .x2(GX), .y2(GY), .z2(256'd1),
                            .x3(ax), .y3(ay), .z3(az));

    wire bit_now = k_reg[i[7:0]];

    // affine 化
    reg          aff_start;
    wire         aff_done;
    wire [255:0] aff_x, aff_y;
    ec_to_affine u_aff (.clk(clk), .rst_n(rst_n), .start(aff_start),
                        .x_jac(Px), .y_jac(Py), .z_jac(Pz),
                        .done(aff_done), .x_aff(aff_x), .y_aff(aff_y));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; done <= 0; aff_start <= 0;
            Px <= 0; Py <= 0; Pz <= 0;
            k_reg <= 0; i <= 0; rx <= 0; ry <= 0;
        end else begin
            done      <= 0;
            aff_start <= 0;
            case (st)
            ST_IDLE: if (start) begin
                Px <= 0; Py <= 0; Pz <= 0;     // O
                k_reg <= scalar;
                i  <= 9'd255;
                st <= ST_LOOP;
            end
            ST_LOOP: begin
                if (bit_now) begin
                    Px <= ax; Py <= ay; Pz <= az;
                end else begin
                    Px <= dx; Py <= dy; Pz <= dz;
                end
                if (i == 0) begin
                    aff_start <= 1;
                    st        <= ST_AFF_WAIT;
                end else begin
                    i <= i - 9'd1;
                end
            end
            ST_AFF_WAIT: if (aff_done) begin
                rx   <= aff_x;
                ry   <= aff_y;
                done <= 1;
                st   <= ST_IDLE;
            end
            default: st <= ST_IDLE;
            endcase
        end
    end
endmodule


//------------------------------------------------------------------------------
// mod n 演算器 (n = secp256k1 の群位数)
//   op: 0 = (a + b) mod n
//       1 = (a - b) mod n
//       2 = (a * b) mod n   ← 真の実装はモンゴメリ乗算 (数百サイクル)
//------------------------------------------------------------------------------
module scalar_mod_n (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [1:0]   op,
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg          done,
    output reg  [255:0] result
);
    localparam [255:0] N =
        256'hFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_BAAEDCE6_AF48A03B_BFD25E8C_D0364141;

    reg [3:0] cnt;
    reg       active;

    // 実装注: ここでは数サイクル遅延でビヘイビアモデルとして実装する。
    // 256x256 の乗算は1サイクルでは厳しいので、本格版ではシフト＆加算ループにする。

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; done <= 0; cnt <= 0; result <= 0;
        end else begin
            done <= 0;
            if (start && !active) begin
                active <= 1;
                cnt    <= 0;
            end else if (active) begin
                if (cnt < 4) begin
                    cnt <= cnt + 1;
                end else begin : DO_OP
                    reg [256:0] tmp_add;
                    reg signed [257:0] tmp_sub;
                    reg [511:0] tmp_mul;
                    case (op)
                    2'd0: begin
                        tmp_add = a + b;
                        result <= (tmp_add >= N) ? tmp_add[255:0] - N : tmp_add[255:0];
                    end
                    2'd1: begin
                        if (a >= b) result <= a - b;
                        else        result <= N - (b - a);
                    end
                    2'd2: begin
                        // 簡易: 上位を捨てて剰余 (ビヘイビア用; 厳密でない)
                        tmp_mul = a * b;
                        result  <= tmp_mul % N;   // シミュレーション専用
                    end
                    default: result <= a;
                    endcase
                    done   <= 1;
                    active <= 0;
                end
            end
        end
    end
endmodule
