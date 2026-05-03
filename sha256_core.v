//==============================================================================
// sha256_core.v
//
// SHA-256 コア (FIPS 180-4)  ＋  BIP-340 タグ付きハッシュラッパ
//
//   - sha256_block : 1ブロック (512bit) の圧縮関数。64サイクルで完了。
//   - sha256_top   : 任意長メッセージのパディング＋複数ブロック処理。
//   - tagged_sha256: tagged_hash(tag, x) = sha256(sha256(tag) || sha256(tag) || x)
//                    プリコンピュートされた tag_pre = sha256(tag)||sha256(tag) を入力に取る。
//==============================================================================

`timescale 1ns/1ps

//------------------------------------------------------------------------------
// SHA-256 単一ブロック圧縮関数
//------------------------------------------------------------------------------
module sha256_block (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] h_in,        // 既存ハッシュ値 (8 x 32bit)
    input  wire [511:0] block,       // 入力ブロック (16 x 32bit ワード, big-endian)
    output reg          done,
    output reg  [255:0] h_out
);

    // 初期定数 K[0..63]
    function [31:0] K_const;
        input [5:0] i;
        begin
            case (i)
            6'd00: K_const=32'h428a2f98; 6'd01: K_const=32'h71374491;
            6'd02: K_const=32'hb5c0fbcf; 6'd03: K_const=32'he9b5dba5;
            6'd04: K_const=32'h3956c25b; 6'd05: K_const=32'h59f111f1;
            6'd06: K_const=32'h923f82a4; 6'd07: K_const=32'hab1c5ed5;
            6'd08: K_const=32'hd807aa98; 6'd09: K_const=32'h12835b01;
            6'd10: K_const=32'h243185be; 6'd11: K_const=32'h550c7dc3;
            6'd12: K_const=32'h72be5d74; 6'd13: K_const=32'h80deb1fe;
            6'd14: K_const=32'h9bdc06a7; 6'd15: K_const=32'hc19bf174;
            6'd16: K_const=32'he49b69c1; 6'd17: K_const=32'hefbe4786;
            6'd18: K_const=32'h0fc19dc6; 6'd19: K_const=32'h240ca1cc;
            6'd20: K_const=32'h2de92c6f; 6'd21: K_const=32'h4a7484aa;
            6'd22: K_const=32'h5cb0a9dc; 6'd23: K_const=32'h76f988da;
            6'd24: K_const=32'h983e5152; 6'd25: K_const=32'ha831c66d;
            6'd26: K_const=32'hb00327c8; 6'd27: K_const=32'hbf597fc7;
            6'd28: K_const=32'hc6e00bf3; 6'd29: K_const=32'hd5a79147;
            6'd30: K_const=32'h06ca6351; 6'd31: K_const=32'h14292967;
            6'd32: K_const=32'h27b70a85; 6'd33: K_const=32'h2e1b2138;
            6'd34: K_const=32'h4d2c6dfc; 6'd35: K_const=32'h53380d13;
            6'd36: K_const=32'h650a7354; 6'd37: K_const=32'h766a0abb;
            6'd38: K_const=32'h81c2c92e; 6'd39: K_const=32'h92722c85;
            6'd40: K_const=32'ha2bfe8a1; 6'd41: K_const=32'ha81a664b;
            6'd42: K_const=32'hc24b8b70; 6'd43: K_const=32'hc76c51a3;
            6'd44: K_const=32'hd192e819; 6'd45: K_const=32'hd6990624;
            6'd46: K_const=32'hf40e3585; 6'd47: K_const=32'h106aa070;
            6'd48: K_const=32'h19a4c116; 6'd49: K_const=32'h1e376c08;
            6'd50: K_const=32'h2748774c; 6'd51: K_const=32'h34b0bcb5;
            6'd52: K_const=32'h391c0cb3; 6'd53: K_const=32'h4ed8aa4a;
            6'd54: K_const=32'h5b9cca4f; 6'd55: K_const=32'h682e6ff3;
            6'd56: K_const=32'h748f82ee; 6'd57: K_const=32'h78a5636f;
            6'd58: K_const=32'h84c87814; 6'd59: K_const=32'h8cc70208;
            6'd60: K_const=32'h90befffa; 6'd61: K_const=32'ha4506ceb;
            6'd62: K_const=32'hbef9a3f7; 6'd63: K_const=32'hc67178f2;
            default: K_const = 32'h0;
            endcase
        end
    endfunction

    // ローテート右
    function [31:0] ror; input [31:0] x; input integer n;
        ror = (x >> n) | (x << (32-n));
    endfunction
    function [31:0] s0; input [31:0] x; s0 = ror(x,7) ^ ror(x,18) ^ (x>>3); endfunction
    function [31:0] s1; input [31:0] x; s1 = ror(x,17) ^ ror(x,19) ^ (x>>10); endfunction
    function [31:0] S0; input [31:0] x; S0 = ror(x,2) ^ ror(x,13) ^ ror(x,22); endfunction
    function [31:0] S1; input [31:0] x; S1 = ror(x,6) ^ ror(x,11) ^ ror(x,25); endfunction
    function [31:0] Ch; input [31:0] x,y,z; Ch = (x & y) ^ (~x & z); endfunction
    function [31:0] Maj; input [31:0] x,y,z; Maj = (x & y) ^ (x & z) ^ (y & z); endfunction

    reg [31:0] W [0:63];
    reg [31:0] a,b,c,d,e,f,g,h;
    reg [31:0] hi0,hi1,hi2,hi3,hi4,hi5,hi6,hi7;
    reg [6:0]  cnt;          // 0..64
    reg        active;
    integer    i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; done <= 0; cnt <= 0;
            h_out <= 0;
        end else begin
            done <= 0;
            if (start && !active) begin
                // メッセージスケジュール先頭16ワード
                for (i=0; i<16; i=i+1)
                    W[i] <= block[511 - 32*i -: 32];
                {hi0,hi1,hi2,hi3,hi4,hi5,hi6,hi7} <= h_in;
                {a,b,c,d,e,f,g,h} <= h_in;
                cnt    <= 0;
                active <= 1;
            end else if (active) begin
                // ワーク: cnt が 0..63 まで圧縮
                // メッセージスケジュールは「次のラウンド用」を先行計算する。
                // cnt=0 で W[16] を生成 (W[0..15] から)、cnt=47 で W[63] を生成。
                // これにより cnt=16..63 の COMPRESS が新値 W[cnt] を読める。
                if (cnt < 48) begin
                    W[cnt+16] <= s1(W[cnt+14]) + W[cnt+9] + s0(W[cnt+1]) + W[cnt];
                end
                if (cnt < 64) begin : COMPRESS
                    reg [31:0] T1, T2;
                    T1 = h + S1(e) + Ch(e,f,g) + K_const(cnt[5:0]) + W[cnt];
                    T2 = S0(a) + Maj(a,b,c);
                    h <= g; g <= f; f <= e;
                    e <= d + T1;
                    d <= c; c <= b; b <= a;
                    a <= T1 + T2;
                    cnt <= cnt + 1;
                end else begin
                    // 完了
                    h_out <= {hi0+a, hi1+b, hi2+c, hi3+d,
                              hi4+e, hi5+f, hi6+g, hi7+h};
                    done   <= 1;
                    active <= 0;
                end
            end
        end
    end
endmodule


//------------------------------------------------------------------------------
// SHA-256 トップ (任意長メッセージ、最大 1024bit = 128byte 想定)
//   data       : 上位詰め (MSB側にデータ、LSB側ゼロパディング前の領域)
//   data_len   : バイト長 (0..128)
//   ※ より長いメッセージへ拡張する場合は内部のブロック数ループを増やす。
//------------------------------------------------------------------------------
module sha256_top #(parameter MAX_BYTES = 128) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    input  wire [MAX_BYTES*8-1:0]   data,
    input  wire [11:0]              data_len, // バイト
    input  wire [255:0]             h_init,   // 中間ハッシュ初期値 (通常はSHA-256IV)
    output reg                      done,
    output reg  [255:0]             hash
);
    // SHA-256 IV
    localparam [255:0] IV =
        {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
         32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

    // 内部: パディングして 512bit ブロックを生成し、順次圧縮
    // ここでは最大 2 ブロック (1024bit) まで対応する簡易版。
    // 1ブロック目=data[0..511], 2ブロック目=data[512..1023]+末尾長。

    reg          blk_start;
    wire         blk_done;
    reg  [255:0] h_state;
    reg  [511:0] blk;
    wire [255:0] h_next;

    sha256_block u_blk (
        .clk(clk), .rst_n(rst_n),
        .start(blk_start), .h_in(h_state), .block(blk),
        .done(blk_done), .h_out(h_next)
    );

    reg [2:0] st;
    localparam ST_IDLE=0, ST_BLK1=1, ST_WAIT1=2, ST_BLK2=3, ST_WAIT2=4, ST_DONE=5;

    // パディング: メッセージ末尾に 0x80、その後 0 詰め、最後 64bit に bit長
    reg [1023:0] padded;
    reg [10:0]   total_blocks;

    always @(*) begin
        // バイト長を bit 長に
        // padded = data || 0x80 || 0...0 || (len*8 を 64bit big-endian)
        // 最大 1024bit (= 2ブロック) に収める前提
        // 実装はバレルシフトを伴うため簡略化
    end

    // 注: 上記の padded 生成は合成可能な形に書き直す必要がある。
    //     ここでは簡略のため「呼び出し側が data に 0x80 と長さフィールドまで
    //     含めて渡し、data_len は実バイト長」を伝える前提でも動く構成にする。

    integer total_bits;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; done <= 0; hash <= 0; blk_start <= 0;
            h_state <= IV; blk <= 0; total_blocks <= 0;
        end else begin
            blk_start <= 0;
            done      <= 0;
            case (st)
            ST_IDLE: if (start) begin
                h_state <= h_init;
                // パディング込み合計バイト数の概算
                // (ここでは data_len <= 64 なら 1 ブロックで済む簡易判定)
                if (data_len <= 55)
                    total_blocks <= 1;
                else if (data_len <= 119)
                    total_blocks <= 2;
                else
                    total_blocks <= 2; // 簡易上限
                // 1 ブロック目を準備
                // パディング: data の MSB 側に詰めてあり、その直後に 0x80、末尾に bit 長
                // (簡略実装。実用版ではビットシフタが必要)
                blk <= build_block_1(data, data_len);
                blk_start <= 1;
                st <= ST_WAIT1;
            end
            ST_WAIT1: if (blk_done) begin
                h_state <= h_next;
                if (total_blocks == 1) begin
                    hash <= h_next; done <= 1; st <= ST_IDLE;
                end else begin
                    blk       <= build_block_2(data, data_len);
                    blk_start <= 1;
                    st        <= ST_WAIT2;
                end
            end
            ST_WAIT2: if (blk_done) begin
                hash <= h_next; done <= 1; st <= ST_IDLE;
            end
            endcase
        end
    end

    // ----- パディングヘルパ (function 内ループで生成) -----
    // MAX_BYTES = 128 (= 1024 bit) を前提にした簡易パディング。
    // 任意 MAX_BYTES への一般化は後段の TODO。
    function [511:0] build_block_1;
        input [1023:0] dat;
        input [11:0]   dl;
        reg   [1023:0] bbuf;
        reg   [63:0]   bits;
        begin
            bits = dl * 8;
            bbuf = dat;                              // dat は MSB 詰めで渡される前提
            bbuf[1024 - bits - 8 +: 8] = 8'h80;      // 0x80 マーカー
            if (dl <= 55)
                bbuf[575:512] = bits[63:0];          // 1 ブロック完結時の length 位置
            else
                bbuf[63:0]   = bits[63:0];           // 2 ブロック時の length 位置
            build_block_1 = bbuf[1023:512];
        end
    endfunction

    function [511:0] build_block_2;
        input [1023:0] dat;
        input [11:0]   dl;
        reg   [1023:0] bbuf;
        reg   [63:0]   bits;
        begin
            bits = dl * 8;
            bbuf = dat;
            bbuf[1024 - bits - 8 +: 8] = 8'h80;
            bbuf[63:0] = bits[63:0];
            build_block_2 = bbuf[511:0];
        end
    endfunction

endmodule


//------------------------------------------------------------------------------
// BIP-340 タグ付きハッシュラッパ
//   tagged_hash(tag, x) = sha256( sha256(tag) || sha256(tag) || x )
//   tag_pre = sha256(tag) || sha256(tag) (512bit) を事前計算入力する。
//------------------------------------------------------------------------------
module tagged_sha256 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [511:0] tag_pre,         // sha256(tag)||sha256(tag)
    input  wire [1023:0] data,           // 続く本体データ (上位詰め)
    input  wire [11:0]  data_len,        // バイト長
    output reg          done,
    output wire [255:0] hash
);
    // 連結: tag_pre (64B) || data
    // 全体長 = 64 + data_len
    wire [11:0] total_len = data_len + 12'd64;

    // 簡易: 全体を 1024bit バッファに上位詰めして sha256_top に渡す
    // (data_len <= 64 までを想定)
    wire [1023:0] all_data = {tag_pre, data[1023:512]};  // 64B + 先頭64B

    localparam [255:0] IV =
        {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
         32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

    reg start_d;
    always @(posedge clk) start_d <= start;

    sha256_top #(.MAX_BYTES(128)) u_top (
        .clk(clk), .rst_n(rst_n),
        .start(start_d),
        .data(all_data),
        .data_len(total_len),
        .h_init(IV),
        .done(done_w),
        .hash(hash)
    );
    wire done_w;
    always @(posedge clk) done <= done_w;

endmodule
