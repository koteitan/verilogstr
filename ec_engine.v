//==============================================================================
// ec_engine.v
//   Microcoded secp256k1 scalar multiplier (k*G).
//   - 1 つの ALU (ADD_P / SUB_P / MUL_P combinational, INV_P sequential) を共有
//   - 16 x 256-bit register file (R0=0, R1=1, R2=GX, R3=GY は読み出し専用定数)
//   - 6-bit PC + 8-bit bit_idx + 32-bit microinstruction ROM (64 entries)
//   - 「巨大な combinational dbl/add」を「ALU を多重化するマイクロコード」に
//     置き換えることで Fmax を稼ぐ典型的な ECC アクセラレータ構成。
//==============================================================================
`timescale 1ns/1ps

module ec_engine (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] scalar,
    output reg          done,
    output reg  [255:0] rx,
    output reg  [255:0] ry
);

    //--------------------------------------------------------------------------
    // 定数
    //--------------------------------------------------------------------------
    localparam [255:0] GX =
        256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    localparam [255:0] GY =
        256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;

    //--------------------------------------------------------------------------
    // Opcodes
    //--------------------------------------------------------------------------
    localparam [3:0] OP_ADD  = 4'd0;
    localparam [3:0] OP_SUB  = 4'd1;
    localparam [3:0] OP_MUL  = 4'd2;
    localparam [3:0] OP_INV  = 4'd3;
    localparam [3:0] OP_MOV  = 4'd4;
    localparam [3:0] OP_LDB  = 4'd5;  // if scalar[bit_idx]==1: PC=imm
    localparam [3:0] OP_LDBN = 4'd6;  // if scalar[bit_idx]==0: PC=imm
    localparam [3:0] OP_DECB = 4'd7;  // bit_idx>0 ? (bit_idx--, PC=imm) : PC++
    localparam [3:0] OP_SETB = 4'd8;  // bit_idx=255
    localparam [3:0] OP_JMP  = 4'd9;
    localparam [3:0] OP_HALT = 4'd10;
    localparam [3:0] OP_BZ   = 4'd11; // if regfile[ra]==0: PC=imm

    //--------------------------------------------------------------------------
    // Register file (16 x 256-bit)
    //   R0=0, R1=1, R2=GX, R3=GY  は read-only  (writes to rd<4 are ignored)
    //--------------------------------------------------------------------------
    reg [255:0] regfile [4:15];

    //--------------------------------------------------------------------------
    // PC / bit_idx / running
    //--------------------------------------------------------------------------
    reg [5:0] pc;
    reg [7:0] bit_idx;
    reg       running;
    reg       inv_active;

    //--------------------------------------------------------------------------
    // Microinstruction ROM
    //   format: [31:28]=op  [27:24]=rd  [23:20]=ra  [19:16]=rb  [15:0]=imm
    //--------------------------------------------------------------------------
    function [31:0] enc;
        input [3:0] o;
        input [3:0] d;
        input [3:0] a;
        input [3:0] b;
        input [15:0] i;
        begin
            enc = {o, d, a, b, i};
        end
    endfunction

    function [31:0] ucode;
        input [5:0] addr;
        begin
            case (addr)
                // ----- init -----
                6'd0:  ucode = enc(OP_SETB, 4'd0,  4'd0,  4'd0, 16'd0);
                6'd1:  ucode = enc(OP_MOV,  4'd5,  4'd0,  4'd0, 16'd0);  // PX = 0
                6'd2:  ucode = enc(OP_MOV,  4'd6,  4'd0,  4'd0, 16'd0);  // PY = 0
                6'd3:  ucode = enc(OP_MOV,  4'd7,  4'd0,  4'd0, 16'd0);  // PZ = 0

                // ----- dbl(P) -> (R13=DX, R10=DY, R14=DZ) -----
                6'd4:  ucode = enc(OP_MUL,  4'd8,  4'd5,  4'd5, 16'd0);  // A = X1^2
                6'd5:  ucode = enc(OP_MUL,  4'd9,  4'd6,  4'd6, 16'd0);  // B = Y1^2
                6'd6:  ucode = enc(OP_MUL,  4'd10, 4'd9,  4'd9, 16'd0);  // C = B^2
                6'd7:  ucode = enc(OP_ADD,  4'd11, 4'd5,  4'd9, 16'd0);  // T = X1+B
                6'd8:  ucode = enc(OP_MUL,  4'd11, 4'd11, 4'd11, 16'd0); // T = T^2
                6'd9:  ucode = enc(OP_SUB,  4'd11, 4'd11, 4'd8, 16'd0);  // T = T-A
                6'd10: ucode = enc(OP_SUB,  4'd11, 4'd11, 4'd10, 16'd0); // T = T-C
                6'd11: ucode = enc(OP_ADD,  4'd11, 4'd11, 4'd11, 16'd0); // D = 2T
                6'd12: ucode = enc(OP_ADD,  4'd12, 4'd8,  4'd8, 16'd0);  // 2A
                6'd13: ucode = enc(OP_ADD,  4'd12, 4'd12, 4'd8, 16'd0);  // E = 3A
                6'd14: ucode = enc(OP_MUL,  4'd13, 4'd12, 4'd12, 16'd0); // F = E^2
                6'd15: ucode = enc(OP_ADD,  4'd14, 4'd11, 4'd11, 16'd0); // 2D
                6'd16: ucode = enc(OP_SUB,  4'd13, 4'd13, 4'd14, 16'd0); // DX = F - 2D
                6'd17: ucode = enc(OP_ADD,  4'd14, 4'd10, 4'd10, 16'd0); // 2C
                6'd18: ucode = enc(OP_ADD,  4'd14, 4'd14, 4'd14, 16'd0); // 4C
                6'd19: ucode = enc(OP_ADD,  4'd14, 4'd14, 4'd14, 16'd0); // 8C
                6'd20: ucode = enc(OP_SUB,  4'd10, 4'd11, 4'd13, 16'd0); // DmX = D - DX
                6'd21: ucode = enc(OP_MUL,  4'd10, 4'd12, 4'd10, 16'd0); // E*(D-DX)
                6'd22: ucode = enc(OP_SUB,  4'd10, 4'd10, 4'd14, 16'd0); // DY
                6'd23: ucode = enc(OP_MUL,  4'd14, 4'd6,  4'd7, 16'd0);  // Y1*Z1
                6'd24: ucode = enc(OP_ADD,  4'd14, 4'd14, 4'd14, 16'd0); // DZ = 2*Y1*Z1

                // bit decision
                6'd25: ucode = enc(OP_LDBN, 4'd0,  4'd0,  4'd0, 16'd50); // bit==0 -> NO_ADD
                6'd26: ucode = enc(OP_BZ,   4'd0,  4'd7,  4'd0, 16'd54); // PZ==0 (P=O) -> INIT_G

                // ----- mixed add: (DX,DY,DZ) + (GX,GY,1) -----
                6'd27: ucode = enc(OP_MUL,  4'd8,  4'd14, 4'd14, 16'd0); // z1sq
                6'd28: ucode = enc(OP_MUL,  4'd9,  4'd2,  4'd8, 16'd0);  // u2
                6'd29: ucode = enc(OP_SUB,  4'd9,  4'd9,  4'd13, 16'd0); // H = u2 - DX
                6'd30: ucode = enc(OP_MUL,  4'd11, 4'd8,  4'd14, 16'd0); // z1cb
                6'd31: ucode = enc(OP_MUL,  4'd12, 4'd3,  4'd11, 16'd0); // s2
                6'd32: ucode = enc(OP_SUB,  4'd12, 4'd12, 4'd10, 16'd0); // s2 - DY
                6'd33: ucode = enc(OP_ADD,  4'd12, 4'd12, 4'd12, 16'd0); // r = 2*(s2-DY)
                6'd34: ucode = enc(OP_ADD,  4'd8,  4'd9,  4'd9, 16'd0);  // 2H
                6'd35: ucode = enc(OP_MUL,  4'd11, 4'd8,  4'd8, 16'd0);  // I = (2H)^2
                6'd36: ucode = enc(OP_MUL,  4'd15, 4'd9,  4'd11, 16'd0); // J = H*I
                6'd37: ucode = enc(OP_MUL,  4'd8,  4'd13, 4'd11, 16'd0); // V = DX*I
                6'd38: ucode = enc(OP_MUL,  4'd11, 4'd12, 4'd12, 16'd0); // r^2
                6'd39: ucode = enc(OP_SUB,  4'd5,  4'd11, 4'd15, 16'd0); // PX = r^2 - J
                6'd40: ucode = enc(OP_ADD,  4'd11, 4'd8,  4'd8, 16'd0);  // 2V
                6'd41: ucode = enc(OP_SUB,  4'd5,  4'd5,  4'd11, 16'd0); // PX -= 2V
                6'd42: ucode = enc(OP_SUB,  4'd11, 4'd8,  4'd5, 16'd0);  // VmX = V - PX
                6'd43: ucode = enc(OP_MUL,  4'd11, 4'd12, 4'd11, 16'd0); // r*(V-PX)
                6'd44: ucode = enc(OP_MUL,  4'd8,  4'd10, 4'd15, 16'd0); // DY*J
                6'd45: ucode = enc(OP_ADD,  4'd8,  4'd8,  4'd8, 16'd0);  // 2*DY*J
                6'd46: ucode = enc(OP_SUB,  4'd6,  4'd11, 4'd8, 16'd0);  // PY = r(V-PX) - 2*DY*J
                6'd47: ucode = enc(OP_ADD,  4'd11, 4'd14, 4'd14, 16'd0); // 2*DZ
                6'd48: ucode = enc(OP_MUL,  4'd7,  4'd11, 4'd9, 16'd0);  // PZ = 2*DZ*H
                6'd49: ucode = enc(OP_JMP,  4'd0,  4'd0,  4'd0, 16'd57); // -> NEXT_ITER

                // ----- NO_ADD: P = D -----  (target of LDBN at PC=25)
                6'd50: ucode = enc(OP_MOV,  4'd5,  4'd13, 4'd0, 16'd0);
                6'd51: ucode = enc(OP_MOV,  4'd6,  4'd10, 4'd0, 16'd0);
                6'd52: ucode = enc(OP_MOV,  4'd7,  4'd14, 4'd0, 16'd0);
                6'd53: ucode = enc(OP_JMP,  4'd0,  4'd0,  4'd0, 16'd57); // -> NEXT_ITER

                // ----- INIT_G: P = G ----- (target of BZ at PC=26)
                6'd54: ucode = enc(OP_MOV,  4'd5,  4'd2,  4'd0, 16'd0);  // PX = GX
                6'd55: ucode = enc(OP_MOV,  4'd6,  4'd3,  4'd0, 16'd0);  // PY = GY
                6'd56: ucode = enc(OP_MOV,  4'd7,  4'd1,  4'd0, 16'd0);  // PZ = 1
                                                                          // fall through to NEXT_ITER

                // ----- NEXT_ITER -----
                6'd57: ucode = enc(OP_DECB, 4'd0,  4'd0,  4'd0, 16'd4);  // bit_idx--; if was>0 -> LOOP

                // ----- to affine -----
                6'd58: ucode = enc(OP_INV,  4'd8,  4'd7,  4'd0, 16'd0);  // Zinv = inv(PZ)
                6'd59: ucode = enc(OP_MUL,  4'd9,  4'd8,  4'd8, 16'd0);  // Zinv^2
                6'd60: ucode = enc(OP_MUL,  4'd10, 4'd9,  4'd8, 16'd0);  // Zinv^3
                6'd61: ucode = enc(OP_MUL,  4'd5,  4'd5,  4'd9, 16'd0);  // rx
                6'd62: ucode = enc(OP_MUL,  4'd6,  4'd6,  4'd10, 16'd0); // ry
                6'd63: ucode = enc(OP_HALT, 4'd0,  4'd0,  4'd0, 16'd0);

                default: ucode = enc(OP_HALT, 4'd0, 4'd0, 4'd0, 16'd0);
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // Decode
    //--------------------------------------------------------------------------
    wire [31:0] inst = ucode(pc);
    wire [3:0]  op   = inst[31:28];
    wire [3:0]  rd   = inst[27:24];
    wire [3:0]  ra   = inst[23:20];
    wire [3:0]  rb   = inst[19:16];
    wire [15:0] imm  = inst[15:0];

    //--------------------------------------------------------------------------
    // RegFile read (R0..R3 are read-only constants).
    // function 内の配列参照だと iverilog で stale value を返す挙動があったため、
    // インライン mux で書く。
    //--------------------------------------------------------------------------
    wire [255:0] a_val = (ra == 4'd0) ? 256'd0 :
                         (ra == 4'd1) ? 256'd1 :
                         (ra == 4'd2) ? GX     :
                         (ra == 4'd3) ? GY     :
                                        regfile[ra];
    wire [255:0] b_val = (rb == 4'd0) ? 256'd0 :
                         (rb == 4'd1) ? 256'd1 :
                         (rb == 4'd2) ? GX     :
                         (rb == 4'd3) ? GY     :
                                        regfile[rb];

    //--------------------------------------------------------------------------
    // ALU 共有: ADD_P / SUB_P / MUL_P (combinational), INV_P (sequential)
    //--------------------------------------------------------------------------
    wire [255:0] add_r, sub_r, mul_r;
    field_add_p u_add (.a(a_val), .b(b_val), .r(add_r));
    field_sub_p u_sub (.a(a_val), .b(b_val), .r(sub_r));
    field_mul_p u_mul (.a(a_val), .b(b_val), .r(mul_r));

    reg          inv_start;
    wire         inv_done;
    wire [255:0] inv_r;
    field_inv_p u_inv (.clk(clk), .rst_n(rst_n), .start(inv_start),
                       .a(a_val), .done(inv_done), .r(inv_r));

    //--------------------------------------------------------------------------
    // Sequencer
    //--------------------------------------------------------------------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0; done <= 1'b0; pc <= 6'd0; bit_idx <= 8'd0;
            inv_start <= 1'b0; inv_active <= 1'b0;
            rx <= 256'd0; ry <= 256'd0;
            for (k = 4; k <= 15; k = k + 1) regfile[k] <= 256'd0;
        end else begin
            done      <= 1'b0;
            inv_start <= 1'b0;

            if (!running) begin
                if (start) begin
                    running <= 1'b1;
                    pc      <= 6'd0;
                end
            end else begin
                case (op)
                    OP_ADD: begin
                        if (rd >= 4) regfile[rd] <= add_r;
                        pc <= pc + 6'd1;
                    end
                    OP_SUB: begin
                        if (rd >= 4) regfile[rd] <= sub_r;
                        pc <= pc + 6'd1;
                    end
                    OP_MUL: begin
                        if (rd >= 4) regfile[rd] <= mul_r;
                        pc <= pc + 6'd1;
                    end
                    OP_MOV: begin
                        if (rd >= 4) regfile[rd] <= a_val;
                        pc <= pc + 6'd1;
                    end
                    OP_INV: begin
                        if (!inv_active) begin
                            inv_start  <= 1'b1;
                            inv_active <= 1'b1;
                        end else if (inv_done) begin
                            if (rd >= 4) regfile[rd] <= inv_r;
                            inv_active <= 1'b0;
                            pc         <= pc + 6'd1;
                        end
                    end
                    OP_LDB: begin
                        pc <= scalar[bit_idx] ? imm[5:0] : (pc + 6'd1);
                    end
                    OP_LDBN: begin
                        pc <= scalar[bit_idx] ? (pc + 6'd1) : imm[5:0];
                    end
                    OP_DECB: begin
                        if (bit_idx != 8'd0) begin
                            bit_idx <= bit_idx - 8'd1;
                            pc      <= imm[5:0];
                        end else begin
                            pc <= pc + 6'd1;
                        end
                    end
                    OP_SETB: begin
                        bit_idx <= 8'd255;
                        pc      <= pc + 6'd1;
                    end
                    OP_JMP: begin
                        pc <= imm[5:0];
                    end
                    OP_BZ: begin
                        pc <= (a_val == 256'd0) ? imm[5:0] : (pc + 6'd1);
                    end
                    OP_HALT: begin
                        rx      <= regfile[5];
                        ry      <= regfile[6];
                        done    <= 1'b1;
                        running <= 1'b0;
                        pc      <= 6'd0;
                    end
                    default: pc <= pc + 6'd1;
                endcase
            end
        end
    end

endmodule
