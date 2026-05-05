[English](README.md) | [Japanese](README-ja.md)

# Nostr 署名 (BIP-340 Schnorr / secp256k1) Verilog 実装

version: v0.1.5

Nostr のイベント署名をハードウェアで実装するための Verilog コードの **設計骨格** です。

## ファイル構成

| ファイル              | 内容                                                          |
|----------------------|---------------------------------------------------------------|
| `nostr_sign.v`       | トップモジュール。BIP-340 Schnorr 署名のステートマシン本体     |
| `sha256_core.v`      | SHA-256 圧縮関数 + 任意長 (≦183B) メッセージ + タグ付きハッシュラッパ |
| `ec_arith.v`         | secp256k1 mod p 算術 (add/sub/mul/inv 組合せ版) と Jacobian 点演算 |
| `field_seq.v`        | 合成可能な sequential 256-cycle 乗算器 + Fermat 法逆元 (~131k cycle) |
| `ec_engine.v`        | プログラマブル EC エンジン (ALU 共有 + RegFile + microcode ROM) — `nostr_sign` の `k*G` で使用 |
| `tb_nostr_sign.v`    | BIP-340 公式テストベクタ v0〜v3                                |
| `tb_hello_world.v`   | 実 Nostr イベント (kind:1, "hello world") 署名デモ             |
| `tb_sha256_*.v` / `tb_field_*.v` / `tb_ec_*.v` | 各下位モジュールの単体 TB                |

## 署名アルゴリズム (BIP-340)

```
入力: 秘密鍵 d, メッセージ m, 補助乱数 a
1. d' = d if (d*G).y is even else n - d
2. t  = d' xor tagged_hash("BIP0340/aux", a)
3. k' = int(tagged_hash("BIP0340/nonce", t || P.x || m)) mod n
4. R  = k' * G
5. k  = k' if R.y is even else n - k'
6. e  = int(tagged_hash("BIP0340/challenge", R.x || P.x || m)) mod n
7. 署名 = (R.x, (k + e*d') mod n)
```

`tagged_hash(tag, x) = sha256(sha256(tag) || sha256(tag) || x)`

## 実装状況と課題

BIP-340 Schnorr 署名のロジックはシミュレータ上で公式テストベクタにビット完全
一致まで動作します。一方で「実 FPGA / ASIC に載せる」観点では以下が残課題です。

### ✅ 完了済
- Jacobian 座標 (a=0) の点二倍 / 加算 / 公開鍵 X 座標取得 / R.y 偶奇判定 (`ec_arith.v`)
- Double-and-add の 256 反復スカラー倍 (`ec_engine.v`, ALU 共有)
- mod p フィールド算術 (fast reduction で合成可能, `field_*_p`)
- mod p 逆元 (Fermat 法, `field_inv_p`)
- BIP-340 タグ付きハッシュ定数 (aux/nonce/challenge) 埋め込み
- SHA-256 を最大 3 ブロック (≦183B) パディングまで拡張
- BIP-340 公式テストベクタ v0〜v3 ビット完全一致
- Nostr 実イベント (kind:1, "hello world") 署名 → 外部 verify VALID

### ⚠️ 未完了 (合成可能化 / プロダクション化に向けた残作業)

#### 1. (完了済) mod n 乗算の sequential 化 (`scalar_mod_n`)
v0.1.4 で `(a*b) mod n` を 256-cycle shift-and-add + 2 段減算還元に置換済。
**`nostr_sign` 全体が完全に LUT4 マップ可能** (Yosys で約 68,950 LUT4 +
16,509 FF を確認)。

#### 2. (完了済) サイドチャネル対策 (constant-time 化)
v0.1.5 で always-double-and-add + bitwise CMOV mux に書き換え済。
新オペコード `OP_CMOV_NB` / `OP_CMOV_BZ` を追加し、分岐 `LDBN` / `BZ` を排除。

**`tb_ec_engine` での constant-time 実証** (`k*G` を異なる k で実行):

| スカラー k | サイクル数      | 結果   |
|----------:|--------------:|:-------|
|         1 | **1,338,628** | ✅ PASS |
|         2 | **1,338,628** | ✅ PASS |
|         3 | **1,338,628** | ✅ PASS |
|         5 | **1,338,628** | ✅ PASS |

スカラーのビットパターンが異なるのに **全て同じサイクル数** で完了 ─
タイミング攻撃 (実行時間からの秘密鍵漏洩) が原理的に無効化されています。

#### 3. (完了済) `field_mul_p` の sequential 化
v0.1.3 で `field_seq_mul_p` (256-cycle shift-and-add) に置換済。
~3.4k LUT4 で合成可能、Fmax 200 MHz 級が見込めます。

#### 4. `field_inv_p` の高速化
Fermat 法 (256+ cycle) を binary GCD 系に置き換えれば数十 cycle で済みます。
`ec_to_affine` を頻繁に呼ぶ場合に効果大。

#### 5. 任意長 message
`nostr_sign` の `msg` は 32B 固定 (Nostr の event_id 前提)。BIP-340 公式
ベクタ v15 以降の可変長 msg を扱うには事前 SHA256 (= 32B 圧縮) を上位で
噛ませるか、`sha256_top` のブロック数をさらに拡張する必要があります。

#### 6. 鍵投入 I/F
現状は `[255:0]` の parallel ポート。SPI / AXI 等のシリアル I/F を経由した
鍵注入を入れると HSM 風用途に使えます。

#### 7. 実 relay 投入
署名済イベントを `wss://...` に WebSocket で送って実際に受理されるかの確認。


## 推奨される進め方

現状の `field_mul_p` が combinational なため、本コード全体は **数十万〜数百万
LUT4 規模** (詳細は下記「回路規模」参照)。Montgomery 乗算器化で 1〜2 桁の面積
削減が見込めますが、それでも組込み IoT 向けには大きいので用途次第で:

| 方式 | 内容 |
|---|---|
| 全 HW | 本コードを Montgomery 化して全実装。鍵の HW 隔離が完璧 |
| HSM 風 | 楕円曲線部分だけ HW、ハッシュ・パディング等はソフト |
| Co-processor | secp256k1 IP コア (例: ECDSA/Schnorr アクセラレータ) を購入して FPGA に載せる |

## ビルド/シミュレーション例 (Icarus Verilog)

```sh
iverilog -o sim nostr_sign.v sha256_core.v ec_arith.v tb_nostr_sign.v
vvp sim
gtkwave nostr_sign.vcd
```

## 動作実例: Verilog で署名した Nostr イベント

`tb_hello_world.v` で適当な秘密鍵を使い、`kind:1 / content:"hello world"`
の Nostr イベントを Verilog (Icarus iverilog) シミュレータ上で署名した結果。
署名は **programmable EC engine 版 (`ec_engine.v`)** を経由した nostr_sign で
生成し、外部の Python リファレンス実装で BIP-340 verify = **VALID** を確認済。

| 項目         | 値                                                                   |
|-------------|---------------------------------------------------------------------|
| `nsec1`     | `nsec1kzlc50ntfsxnrf0z7r657zsj8rr73ge0tkv7x9r2ttgjh062rjfs5hqm5t`     |
| `npub1`     | `npub14xurjwprdu2ug5hl20qwhh3y766jlxhfefrcyxxyaj7x0sxzzssqn4exwz`     |
| `created_at`| `1700000000`                                                         |
| `event_id`  | `871ce455cfdbaf3deb04a8f101494df9142fc1f9eeba8fc6d0934768f4063062`   |
| `sig (R)`   | `a6c159cc30a14de9d2a8502fc3354e01c8d63d2a3c7fb2e9ee7c94a9b4a29d97`   |
| `sig (s)`   | `1e61ef9d59f81885c928203d308466b73a0c7316afe23aa819637d4b06137ac4`   |
| start→done  | `2,678,083 cycles` (clk=100MHz 換算で 26.8 ms; constant-time)         |

署名済イベント (relay へ `["EVENT", ...]` で送信可能):

```json
{
  "id": "871ce455cfdbaf3deb04a8f101494df9142fc1f9eeba8fc6d0934768f4063062",
  "pubkey": "a9b83938236f15c452ff53c0ebde24f6b52f9ae9ca478218c4ecbc67c0c21420",
  "created_at": 1700000000,
  "kind": 1,
  "tags": [],
  "content": "hello world",
  "sig": "a6c159cc30a14de9d2a8502fc3354e01c8d63d2a3c7fb2e9ee7c94a9b4a29d971e61ef9d59f81885c928203d308466b73a0c7316afe23aa819637d4b06137ac4"
}
```

BIP-340 公式テストベクタ (`tb_nostr_sign.v` の v0〜v3) も同様にビット完全一致で
通過することを確認済。

## 回路規模 (Yosys 0.9 で合成、`synth → abc -lut 4` 後の概算)

シミュレーション behavioral モデルとして書かれているため、本コードは
**combinational な 256x256 multiplier を多数並列でインスタンス化**しており、
そのまま FPGA に載せるには非現実的なサイズです。Montgomery 乗算器で 1 個を
時分割使用する形に書き換えるのが本格実装の前提となります (TODO 項目 2)。

| モジュール             | LUT4   | FF      | 備考                                    |
|----------------------|-------:|--------:|-----------------------------------------|
| `field_seq_mul_p`    |  3.4 k |  1.0 k  | sequential 256 サイクル × 1 (合成可能)    |
| `field_seq_inv_p`    |  ~7 k  |  ~1.5 k | Fermat 法 ~131k cycle (mul を共有再利用)   |
| `sha256_block`       |   13 k |  ~2.8 k | FIPS 180-4 圧縮関数 (64 サイクル)         |
| `sha256_top`         |   11 k |  ~2.8 k | パディング+最大 3 ブロック対応            |
| `ec_engine`          |   39 k |  ~7.5 k | 256-bit ALU 共有 + RegFile + microcode ROM |

`nostr_sign` 全体 (`ec_engine` 経由, 技術非依存 cell 数, `synth` 前):

| 指標                                  | 値        |
|--------------------------------------|----------:|
| Cells (total, before synth)           | 6,148     |
| `$mul` (small ×977 inside reduction)  | 4         |
| `$mod`                                | **0**     |
| `$add` / `$sub`                       | 42 / 15   |
| LUT4 (after `synth → abc -lut 4`)     | **83,670** |
| FF                                    | 16,509    |

**`$mod` セルが消滅し、`nostr_sign` 全体が LUT4 マップ可能**になりました。
68k LUT4 は Stratix 10 GX 10M (~10M LE) どころか中型の Artix-7 / Cyclone V
クラスにも余裕で載るサイズです。

`scalar_mod_n` がシミュレーション用に `%` 演算子を含むため、`nostr_sign`
トップを LUT4 にマップすると `synth_xilinx` 系でエラーになります。
合成可能化は本格 mod n 乗算器への置換 (実装状況の項目 1) が前提。

## レイテンシとスループット

### 1 署名あたりのサイクル数 (実測)

`tb_hello_world.v` の start→done を計測 (Nostr `kind:1` イベント 1 件分):
**2,678,083 cycles** (constant-time always-double-and-add で、スカラーに
依存しない一定サイクル。1 mul = 256 cycle, 1 inv ≈ 131k cycle)。

### Stratix 10 GX 10M に載せた場合の見込み

| 構成 | 推定 Fmax | 1 署名 | sig/s |
|---|---:|---:|---:|
| 現状 (constant-time, sequential mul)   | ~200 MHz | 13.4 ms | ~75   |
| (理想) Montgomery 乗算器 + pipeline    | ~300 MHz | ~150 µs | ~6,500 |

### 比較: ソフトウェア実装

| 実装 | 1 署名 | sig/s (1 コア) |
|---|---:|---:|
| Apple M3 / Ryzen 7000 (libsecp256k1) | ~30 µs | ~33,000 |
| Intel Xeon Skylake (libsecp256k1) | ~50 µs | ~20,000 |
| Raspberry Pi 4 (ARM Cortex-A72) | ~200 µs | ~5,000 |
| ESP32 等 MCU | ~5 ms | ~200 |

**スループットでは現代の x86 が 1 桁速い**。HW 化の動機は速度ではなく:

- **電力効率** (CPU の W オーダー → mW オーダー)
- **鍵の物理隔離** (秘密鍵が SW に決して触れない HSM 用途)
- **決定論的レイテンシ** (OS 割込みやキャッシュミスの影響を受けない)
- **並列化容易性** (ASIC で数十並列 → 数百 k sig/s)
