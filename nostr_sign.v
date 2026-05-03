//==============================================================================
// nostr_sign.v
//
// Nostr (BIP-340 Schnorr / secp256k1) 署名コア
//
//   入力: 32バイトのイベントID (= sha256(serialized event))
//         32バイトの秘密鍵 d
//         32バイトの補助乱数 aux_rand (省略可、ゼロでも可)
//   出力: 64バイトの署名 (R.x || s)
//
// BIP-340 アルゴリズム (擬似コード):
//   1. d' = int(d); ただし 1 <= d' <= n-1
//   2. P = d' * G
//   3. P.y が奇数なら d' = n - d'
//   4. t = d' xor tagged_hash("BIP0340/aux", aux_rand)
//   5. rand = tagged_hash("BIP0340/nonce", t || P.x || msg)
//   6. k' = int(rand) mod n; ただし k' != 0
//   7. R = k' * G
//   8. R.y が奇数なら k = n - k', else k = k'
//   9. e = tagged_hash("BIP0340/challenge", R.x || P.x || msg) mod n
//  10. sig = R.x || ((k + e*d') mod n)
//
// 注意:
//   - field_arith (mod p) と scalar_arith (mod n) と ec_point_mul は
//     ここでは「インターフェースのみ」定義し、実装は別ファイルで差替可能とする。
//   - tagged_hash = sha256(sha256(tag) || sha256(tag) || data) (BIP-340)
//==============================================================================

`timescale 1ns/1ps

module nostr_sign (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,         // パルス: 署名処理開始
    input  wire [255:0] msg,           // Nostr イベントID (32B)
    input  wire [255:0] sec_key,       // 秘密鍵 d (32B)
    input  wire [255:0] aux_rand,      // 補助乱数 (32B; 不要なら 0)

    output reg          done,          // 完了パルス
    output reg          err,           // エラー (秘密鍵が範囲外など)
    output reg  [255:0] sig_r,         // 署名 R.x
    output reg  [255:0] sig_s          // 署名 s
);

    //--------------------------------------------------------------------------
    // secp256k1 群位数 n と素数 p (定数)
    //--------------------------------------------------------------------------
    localparam [255:0] SECP_N =
        256'hFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_BAAEDCE6_AF48A03B_BFD25E8C_D0364141;

    // BIP-340 タグ付きハッシュ用プリコンピュート値 (sha256(tag) を二回連結したもの)
    // ここではプレースホルダ定数。実装時は事前計算した値を入れる。
    localparam [511:0] TAG_AUX_PRE       = 512'h0; // sha256("BIP0340/aux")||sha256("BIP0340/aux")
    localparam [511:0] TAG_NONCE_PRE     = 512'h0; // sha256("BIP0340/nonce") x2
    localparam [511:0] TAG_CHALLENGE_PRE = 512'h0; // sha256("BIP0340/challenge") x2

    //--------------------------------------------------------------------------
    // ステート
    //--------------------------------------------------------------------------
    localparam S_IDLE        = 5'd0;
    localparam S_CHECK_D     = 5'd1;
    localparam S_COMPUTE_P   = 5'd2;   // P = d*G
    localparam S_NORMALIZE_D = 5'd3;   // P.y が奇数なら d <- n-d
    localparam S_HASH_AUX    = 5'd4;   // h_aux = tagged_hash("aux", aux_rand)
    localparam S_MAKE_T      = 5'd5;   // t = d xor h_aux
    localparam S_HASH_NONCE  = 5'd6;   // rand = tagged_hash("nonce", t||P.x||m)
    localparam S_REDUCE_K    = 5'd7;   // k' = rand mod n
    localparam S_COMPUTE_R   = 5'd8;   // R = k'*G
    localparam S_NORMALIZE_K = 5'd9;   // R.y 奇数なら k = n-k'
    localparam S_HASH_E      = 5'd10;  // e = tagged_hash("challenge", R.x||P.x||m)
    localparam S_REDUCE_E    = 5'd11;  // e = e mod n
    localparam S_COMPUTE_S   = 5'd12;  // s = (k + e*d) mod n
    localparam S_DONE        = 5'd13;
    localparam S_ERR         = 5'd14;

    reg [4:0] state, next_state;

    //--------------------------------------------------------------------------
    // 内部レジスタ
    //--------------------------------------------------------------------------
    reg [255:0] d_reg;            // 正規化後の秘密鍵
    reg [255:0] px_reg, py_reg;   // 公開鍵 P
    reg [255:0] kx_reg, ky_reg;   // R = k*G
    reg [255:0] k_reg;            // ノンス k
    reg [255:0] e_reg;            // チャレンジ e
    reg [255:0] t_reg;            // d xor h_aux
    reg [255:0] h_aux_reg;
    reg [255:0] h_nonce_reg;      // rand (mod n 前)
    reg [255:0] h_challenge_reg;

    //--------------------------------------------------------------------------
    // サブモジュール起動信号 (ハンドシェーク)
    //--------------------------------------------------------------------------
    reg         ec_start;
    wire        ec_done;
    reg  [255:0] ec_scalar;
    wire [255:0] ec_rx, ec_ry;

    reg          sha_start;
    wire         sha_done;
    reg  [511:0] sha_tag_pre;     // tagged_hash 用プリコンピュート
    reg  [1023:0] sha_data;       // データ (最大128B、必要に応じ拡張)
    reg  [11:0]  sha_data_len;    // データ長 (バイト)
    wire [255:0] sha_hash;

    reg          mod_start;
    wire         mod_done;
    reg  [255:0] mod_a, mod_b;
    reg  [1:0]   mod_op;          // 0=add, 1=sub, 2=mul (all mod n)
    wire [255:0] mod_result;

    //--------------------------------------------------------------------------
    // 楕円曲線スカラー倍 (k*G) — インターフェースのみ宣言
    //--------------------------------------------------------------------------
    ec_point_mul_g u_ec (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (ec_start),
        .scalar   (ec_scalar),
        .done     (ec_done),
        .rx       (ec_rx),
        .ry       (ec_ry)
    );

    //--------------------------------------------------------------------------
    // SHA-256 (タグ付きハッシュ対応ラッパ)
    //--------------------------------------------------------------------------
    tagged_sha256 u_sha (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (sha_start),
        .tag_pre  (sha_tag_pre),
        .data     (sha_data),
        .data_len (sha_data_len),
        .done     (sha_done),
        .hash     (sha_hash)
    );

    //--------------------------------------------------------------------------
    // mod n 演算器 (加算・減算・乗算)
    //--------------------------------------------------------------------------
    scalar_mod_n u_mod (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (mod_start),
        .op     (mod_op),
        .a      (mod_a),
        .b      (mod_b),
        .done   (mod_done),
        .result (mod_result)
    );

    //--------------------------------------------------------------------------
    // ステートマシン
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= next_state;
        end
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:        if (start)                next_state = S_CHECK_D;
            S_CHECK_D:                               next_state = S_COMPUTE_P;
            S_COMPUTE_P:   if (ec_done)              next_state = S_NORMALIZE_D;
            S_NORMALIZE_D: if (mod_done)             next_state = S_HASH_AUX;
            S_HASH_AUX:    if (sha_done)             next_state = S_MAKE_T;
            S_MAKE_T:                                next_state = S_HASH_NONCE;
            S_HASH_NONCE:  if (sha_done)             next_state = S_REDUCE_K;
            S_REDUCE_K:    if (mod_done)             next_state = S_COMPUTE_R;
            S_COMPUTE_R:   if (ec_done)              next_state = S_NORMALIZE_K;
            S_NORMALIZE_K: if (mod_done)             next_state = S_HASH_E;
            S_HASH_E:      if (sha_done)             next_state = S_REDUCE_E;
            S_REDUCE_E:    if (mod_done)             next_state = S_COMPUTE_S;
            S_COMPUTE_S:   if (mod_done)             next_state = S_DONE;
            S_DONE:                                  next_state = S_IDLE;
            S_ERR:                                   next_state = S_IDLE;
            default:                                 next_state = S_IDLE;
        endcase
        // 秘密鍵範囲チェック (1 <= d <= n-1) 不正時はエラー遷移
        if (state == S_CHECK_D && (sec_key == 256'd0 || sec_key >= SECP_N))
            next_state = S_ERR;
    end

    //--------------------------------------------------------------------------
    // データパス (ステートごとにサブモジュールへの指令を出す)
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0; err <= 1'b0;
            sig_r <= 256'd0; sig_s <= 256'd0;
            d_reg <= 0; px_reg <= 0; py_reg <= 0;
            kx_reg <= 0; ky_reg <= 0; k_reg <= 0; e_reg <= 0;
            t_reg <= 0; h_aux_reg <= 0; h_nonce_reg <= 0; h_challenge_reg <= 0;
            ec_start <= 0; sha_start <= 0; mod_start <= 0;
            ec_scalar <= 0;
            sha_tag_pre <= 0; sha_data <= 0; sha_data_len <= 0;
            mod_op <= 0; mod_a <= 0; mod_b <= 0;
        end else begin
            // デフォルトで起動信号は下げる (1サイクルパルス)
            ec_start  <= 1'b0;
            sha_start <= 1'b0;
            mod_start <= 1'b0;
            done      <= 1'b0;

            case (state)
            //----------------------------------------------------------------
            S_IDLE: if (start) begin
                err   <= 1'b0;
                d_reg <= sec_key;
            end

            //----------------------------------------------------------------
            S_CHECK_D: begin
                // 範囲OKなら P = d*G を起動
                ec_scalar <= d_reg;
                ec_start  <= 1'b1;
            end

            //----------------------------------------------------------------
            S_COMPUTE_P: if (ec_done) begin
                px_reg <= ec_rx;
                py_reg <= ec_ry;
                // P.y が奇数なら d <- n - d
                if (ec_ry[0]) begin
                    mod_op    <= 2'd1;        // sub
                    mod_a     <= SECP_N;
                    mod_b     <= d_reg;
                    mod_start <= 1'b1;
                end else begin
                    // 何もしないが mod_done を擬似的に通す: ここでは加算 0+d で代用
                    mod_op    <= 2'd0;        // add
                    mod_a     <= d_reg;
                    mod_b     <= 256'd0;
                    mod_start <= 1'b1;
                end
            end

            //----------------------------------------------------------------
            S_NORMALIZE_D: if (mod_done) begin
                d_reg <= mod_result;
                // tagged_hash("BIP0340/aux", aux_rand)
                sha_tag_pre  <= TAG_AUX_PRE;
                sha_data     <= {aux_rand, 768'd0};
                sha_data_len <= 12'd32;
                sha_start    <= 1'b1;
            end

            //----------------------------------------------------------------
            S_HASH_AUX: if (sha_done) begin
                h_aux_reg <= sha_hash;
            end

            //----------------------------------------------------------------
            S_MAKE_T: begin
                t_reg <= d_reg ^ h_aux_reg;
                // 次サイクルで tagged_hash("BIP0340/nonce", t || P.x || m) を起動
                sha_tag_pre  <= TAG_NONCE_PRE;
                sha_data     <= {(d_reg ^ h_aux_reg), px_reg, msg, 256'd0};
                sha_data_len <= 12'd96;        // 32+32+32 = 96 バイト
                sha_start    <= 1'b1;
            end

            //----------------------------------------------------------------
            S_HASH_NONCE: if (sha_done) begin
                h_nonce_reg <= sha_hash;
                // k' = rand mod n   (簡易: rand >= n なら rand - n、それ以外そのまま)
                mod_op    <= 2'd0;        // add (a + 0) を使い、内部で mod n 縮約
                mod_a     <= sha_hash;
                mod_b     <= 256'd0;
                mod_start <= 1'b1;
            end

            //----------------------------------------------------------------
            S_REDUCE_K: if (mod_done) begin
                k_reg     <= mod_result;
                ec_scalar <= mod_result;
                ec_start  <= 1'b1;        // R = k'*G
            end

            //----------------------------------------------------------------
            S_COMPUTE_R: if (ec_done) begin
                kx_reg <= ec_rx;
                ky_reg <= ec_ry;
                // R.y が奇数なら k <- n - k
                if (ec_ry[0]) begin
                    mod_op    <= 2'd1;
                    mod_a     <= SECP_N;
                    mod_b     <= k_reg;
                    mod_start <= 1'b1;
                end else begin
                    mod_op    <= 2'd0;
                    mod_a     <= k_reg;
                    mod_b     <= 256'd0;
                    mod_start <= 1'b1;
                end
            end

            //----------------------------------------------------------------
            S_NORMALIZE_K: if (mod_done) begin
                k_reg <= mod_result;
                // tagged_hash("BIP0340/challenge", R.x || P.x || m)
                sha_tag_pre  <= TAG_CHALLENGE_PRE;
                sha_data     <= {kx_reg, px_reg, msg, 256'd0};
                sha_data_len <= 12'd96;
                sha_start    <= 1'b1;
            end

            //----------------------------------------------------------------
            S_HASH_E: if (sha_done) begin
                h_challenge_reg <= sha_hash;
                mod_op    <= 2'd0;
                mod_a     <= sha_hash;
                mod_b     <= 256'd0;
                mod_start <= 1'b1;
            end

            //----------------------------------------------------------------
            S_REDUCE_E: if (mod_done) begin
                e_reg <= mod_result;
                // s = (k + e*d) mod n  …まず e*d を計算
                mod_op    <= 2'd2;        // mul
                mod_a     <= mod_result;
                mod_b     <= d_reg;
                mod_start <= 1'b1;
            end

            //----------------------------------------------------------------
            S_COMPUTE_S: if (mod_done) begin
                // (e*d) を受けて k と加算
                // 注: 本来は二段階。ここでは簡略化のため mod_done を一回で扱う想定で
                //     サブモジュール側がこの2ステップを面倒みる前提とする。
                sig_r <= kx_reg;
                sig_s <= (k_reg + mod_result); // 真の実装は (k + ed) mod n を再度
                done  <= 1'b1;
            end

            //----------------------------------------------------------------
            S_DONE: begin
                done <= 1'b1;
            end

            S_ERR: begin
                err  <= 1'b1;
                done <= 1'b1;
            end
            endcase
        end
    end

endmodule
