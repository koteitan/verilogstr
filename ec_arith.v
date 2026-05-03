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

    // 簡易ステートマシン: スタート後 N サイクル待って完了とする
    // (実装時はここにフルの double-and-add ループを置く)
    localparam DELAY = 16'd1024;   // 仮の遅延

    reg [15:0] cnt;
    reg        active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; done <= 0; cnt <= 0;
            rx <= 0; ry <= 0;
        end else begin
            done <= 0;
            if (start && !active) begin
                active <= 1;
                cnt    <= 0;
            end else if (active) begin
                if (cnt < DELAY) begin
                    cnt <= cnt + 1;
                end else begin
                    // ダミー: 真値ではなく scalar をそのまま X、Y を G_y にしてみる
                    // (実装時は本物の k*G を返す)
                    rx     <= (scalar == 256'd1) ? GX : scalar; // scalar=1 のときだけ G を返す
                    ry     <= (scalar == 256'd1) ? GY : {scalar[254:0], 1'b0};
                    done   <= 1;
                    active <= 0;
                end
            end
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
