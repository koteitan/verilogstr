//==============================================================================
// field_seq.v
//   secp256k1 mod p の sequential 乗算器 (256 サイクル)
//
//   - 機能は field_mul_p と同じ (a * b mod p) — Mont 領域変換は不要
//   - 1 サイクルあたり「z << 1 + a[i]*b」の 513-bit 加算 1 段
//   - 256 サイクル後に 2 段の fast reduction を combinational で適用
//   - 既存 field_mul_p の組合せ実装より小さく (~3k LUT4)、Fmax は高い
//==============================================================================
`timescale 1ns/1ps

module field_seq_mul_p (
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
    localparam [256:0] P2 = {P, 1'b0};

    reg  [512:0] z;            // 累算器 (z << 1 + b で最大 513-bit)
    reg  [255:0] a_reg;         // 左シフトしながら MSB を見る
    reg  [255:0] b_reg;
    reg  [8:0]   i;             // 0..256
    reg          active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0; done <= 1'b0;
            z <= 513'd0; a_reg <= 256'd0; b_reg <= 256'd0;
            i <= 9'd0; r <= 256'd0;
        end else begin
            done <= 1'b0;
            if (start && !active) begin
                z      <= 513'd0;
                a_reg  <= a;
                b_reg  <= b;
                i      <= 9'd0;
                active <= 1'b1;
            end else if (active) begin
                if (i < 9'd256) begin
                    z      <= {z[511:0], 1'b0} +
                              (a_reg[255] ? {257'd0, b_reg} : 513'd0);
                    a_reg  <= {a_reg[254:0], 1'b0};
                    i      <= i + 9'd1;
                end else begin
                    // ----- combinational 2-stage fast reduction -----
                    // z = a*b は最大 2^512 未満
                    r      <= reduce(z[511:0]);
                    done   <= 1'b1;
                    active <= 1'b0;
                end
            end
        end
    end

    // mod p reduction を function 化 (field_mul_p の reduction 部と同じ)
    //   c = 2^32 + 977,  z = zh * 2^256 + zl
    //   z mod p = (zl + zh*c) mod p   (2 段で十分)
    function [255:0] reduce;
        input [511:0] zin;
        reg   [255:0] zh, zl;
        reg   [266:0] m977_zh;
        reg   [288:0] zh_shl32;
        reg   [289:0] zh_c;
        reg   [290:0] t1;
        reg   [34:0]  t1h;
        reg   [255:0] t1l;
        reg   [44:0]  m977_t1h;
        reg   [66:0]  t1h_shl32;
        reg   [67:0]  t1h_c;
        reg   [256:0] t2;
        reg   [256:0] t2_m_p;
        reg   [256:0] t2_m_2p;
        begin
            zh = zin[511:256];
            zl = zin[255:0];
            m977_zh   = 977 * zh;
            zh_shl32  = {zh, 32'h0};
            zh_c      = {1'b0, zh_shl32} + {22'h0, m977_zh};
            t1        = {1'b0, zh_c} + {34'h0, zl};
            t1h       = t1[290:256];
            t1l       = t1[255:0];
            m977_t1h  = 977 * t1h;
            t1h_shl32 = {t1h, 32'h0};
            t1h_c     = {1'b0, t1h_shl32} + {22'h0, m977_t1h};
            t2        = {1'b0, t1l} + {189'h0, t1h_c};
            t2_m_p    = t2 - {1'b0, P};
            t2_m_2p   = t2 - P2;
            reduce    = (t2 >= P2)        ? t2_m_2p[255:0] :
                        (t2 >= {1'b0, P}) ? t2_m_p[255:0]  :
                                            t2[255:0];
        end
    endfunction
endmodule


//==============================================================================
// field_seq_inv_p
//   Fermat 法 a^(p-2) mod p を sequential mul を 1 個共有して実装
//   1 反復に sq + 条件付き mul で最大 ~520 cycles, 256 反復で ~100k cycles
//==============================================================================
module field_seq_inv_p (
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

    // 共有 sequential 乗算器
    reg          mm_start;
    reg  [255:0] mm_a, mm_b;
    wire         mm_done;
    wire [255:0] mm_r;
    field_seq_mul_p u_mm (.clk(clk), .rst_n(rst_n), .start(mm_start),
                          .a(mm_a), .b(mm_b), .done(mm_done), .r(mm_r));

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_MUL_START = 3'd1;
    localparam [2:0] ST_MUL_WAIT  = 3'd2;
    localparam [2:0] ST_SQ_START  = 3'd3;
    localparam [2:0] ST_SQ_WAIT   = 3'd4;
    reg  [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; done <= 1'b0; mm_start <= 1'b0;
            base <= 256'd0; result <= 256'd0; i <= 9'd0;
            mm_a <= 256'd0; mm_b <= 256'd0; r <= 256'd0;
        end else begin
            done     <= 1'b0;
            mm_start <= 1'b0;
            case (state)
                ST_IDLE: if (start) begin
                    base   <= a;
                    result <= 256'd1;
                    i      <= 9'd0;
                    state  <= ST_MUL_START;
                end
                ST_MUL_START: begin
                    if (EXP[i[7:0]]) begin
                        mm_a     <= result;
                        mm_b     <= base;
                        mm_start <= 1'b1;
                        state    <= ST_MUL_WAIT;
                    end else begin
                        state    <= ST_SQ_START;
                    end
                end
                ST_MUL_WAIT: if (mm_done) begin
                    result <= mm_r;
                    state  <= ST_SQ_START;
                end
                ST_SQ_START: begin
                    mm_a     <= base;
                    mm_b     <= base;
                    mm_start <= 1'b1;
                    state    <= ST_SQ_WAIT;
                end
                ST_SQ_WAIT: if (mm_done) begin
                    base <= mm_r;
                    if (i == 9'd255) begin
                        r     <= (EXP[i[7:0]]) ? result : result;
                        // ↑ MUL_WAIT で result は更新済みなのでこれで OK
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        i     <= i + 9'd1;
                        state <= ST_MUL_START;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
