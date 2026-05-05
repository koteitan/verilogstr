//==============================================================================
// field_mont.v
//   secp256k1 mod p の Montgomery 乗算器 (radix-2, 256 サイクル)
//   - 出力 = a*b * R^(-1) mod p   (R = 2^256)
//   - クリティカルパスは 257-bit 加算器 1 段のみで Fmax を稼げる
//   - Mont 領域で計算: x_mont = x * R mod p
//     - MontMul(a_mont, b_mont) = (ab)_mont  (a_mont = a*R, b_mont = b*R, 出力 = abR)
//   - 標準 ↔ Mont 変換は MontMul(x, R^2) と MontMul(x_mont, 1) で行える
//==============================================================================
`timescale 1ns/1ps

module field_mont_mul_p (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg          done,
    output reg  [255:0] r
);
    localparam [255:0] P =
        256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    reg  [255:0] a_reg, b_reg;
    reg  [257:0] T;          // 上限 < 4p < 2^258
    reg  [8:0]   i;          // 0..256
    reg          active;

    // 1 サイクル 1 ビット処理: T <- (T + a[0]*b + ((T[0] + a[0]*b[0]) & 1) * p) >> 1
    // ここでは「T + a[0]*b」を先に算出し、その結果の LSB が 1 なら p を足してから shift
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0; done <= 1'b0;
            T <= 258'd0; a_reg <= 256'd0; b_reg <= 256'd0;
            i <= 9'd0; r <= 256'd0;
        end else begin
            done <= 1'b0;
            if (start && !active) begin
                a_reg  <= a;
                b_reg  <= b;
                T      <= 258'd0;
                i      <= 9'd0;
                active <= 1'b1;
            end else if (active) begin
                if (i < 9'd256) begin : ITER
                    reg [257:0] T1;   // T + a[0]*b
                    reg [257:0] T2;   // T1 + (T1[0]?p:0)
                    T1 = a_reg[0] ? (T + {2'b00, b_reg}) : T;
                    T2 = T1[0]    ? (T1 + {2'b00, P})    : T1;
                    T      <= T2 >> 1;
                    a_reg  <= a_reg >> 1;
                    i      <= i + 9'd1;
                end else begin
                    // 最終調整 (T < 2p なので最大 1 回減算)
                    if (T >= {2'b00, P}) r <= T[255:0] - P;
                    else                 r <= T[255:0];
                    done   <= 1'b1;
                    active <= 1'b0;
                end
            end
        end
    end
endmodule
