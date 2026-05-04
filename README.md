# Nostr 署名 (BIP-340 Schnorr / secp256k1) Verilog 実装

version: v0.1.2

Nostr のイベント署名をハードウェアで実装するための Verilog コードの **設計骨格** です。

## ファイル構成

| ファイル              | 内容                                                          |
|----------------------|---------------------------------------------------------------|
| `nostr_sign.v`       | トップモジュール。BIP-340 Schnorr 署名のステートマシン本体     |
| `sha256_core.v`      | SHA-256 圧縮関数 + 任意長メッセージ + タグ付きハッシュラッパ   |
| `ec_arith.v`         | secp256k1 の点演算 / mod n 演算 (シミュレーション用スタブ)     |
| `tb_nostr_sign.v`    | テストベンチ                                                  |

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

このコードは **アーキテクチャ検証用の骨格** です。実機合成して正しい
署名を生成するには、以下の差し替え/追加が必要です。

### 1. 楕円曲線スカラー倍 (`ec_point_mul_g`)
現在は **ダミー** (固定遅延後にスカラーをそのまま返す) です。
本格実装には:
- Jacobian 座標での点加算 / 点二倍
- Double-and-add アルゴリズム (256 ビットスカラー → ~256 反復)
- サイドチャネル対策 (一定時間化、Montgomery ladder 等)
- secp256k1 mod p のフィールド演算 (Montgomery 乗算器)

### 2. mod n 演算 (`scalar_mod_n`)
加算/減算は OK ですが、乗算 `(a*b) mod n` は **シミュレーション用に
`%` 演算子を使った擬似実装** です。合成不可。
本格実装にはモンゴメリ乗算器が必要 (1 mul あたり ~256 サイクル)。

### 3. SHA-256 のメッセージスケジュール / パディング
コアの圧縮関数は概ね正しい構造ですが:
- パディング (`build_block_1`, `build_block_2`) は最大 119 バイトまで対応の
  簡易版。任意長対応にはバレルシフタが必要
- BIP-340 タグ付きハッシュのプリコンピュート定数 `TAG_AUX_PRE` 等は
  プレースホルダなので、実際の `sha256("BIP0340/aux")` の値を埋め込む必要あり

### 4. テスト
ソフトウェアで:
- BIP-340 の公式テストベクタでビット完全一致を確認
- Nostr の実イベントを署名して relay に流して受理されるか確認

## 推奨される進め方

ハードウェアでフル実装は規模が大きい (おそらく数万 LUT〜十万 LUT 規模)
ので、用途次第では以下のハイブリッドが現実的です:

| 方式 | 内容 |
|---|---|
| 全 HW | 本コードを全部本実装。鍵の HW 隔離が完璧 |
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
得られた署名は外部の Python リファレンス実装で BIP-340 verify = **VALID** を確認済。

| 項目         | 値                                                                   |
|-------------|---------------------------------------------------------------------|
| `nsec1`     | `nsec1kzlc50ntfsxnrf0z7r657zsj8rr73ge0tkv7x9r2ttgjh062rjfs5hqm5t`     |
| `npub1`     | `npub14xurjwprdu2ug5hl20qwhh3y766jlxhfefrcyxxyaj7x0sxzzssqn4exwz`     |
| `created_at`| `1700000000`                                                         |
| `event_id`  | `871ce455cfdbaf3deb04a8f101494df9142fc1f9eeba8fc6d0934768f4063062`   |
| `sig (R)`   | `a6c159cc30a14de9d2a8502fc3354e01c8d63d2a3c7fb2e9ee7c94a9b4a29d97`   |
| `sig (s)`   | `1e61ef9d59f81885c928203d308466b73a0c7316afe23aa819637d4b06137ac4`   |

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
|----------------------|--------|---------|-----------------------------------------|
| `field_mul_p`        |  186 k |     0   | 256x256 mul + 2 段 fast reduction (combinational) |
| `sha256_block`       |   13 k |  ~2.8 k | FIPS 180-4 圧縮関数 (64 サイクル)         |
| `sha256_top`         |   11 k |  ~2.8 k | パディング+最大 3 ブロック対応            |
| `ec_point_mul_g`     | 5,427 k |  ~2.8 k | combinational dbl + add + ec_to_affine + field_inv_p (256 反復) |
| `ec_engine` (programmable, 既定) |   573 k |  ~4.4 k | 256-bit ALU 共有 + RegFile + ROM 形式に書き直したもの (約 1/9.5 サイズ) |

`nostr_sign` 全体 (技術非依存 cell 数, `synth` 前):

| 指標           | 値        |
|---------------|----------|
| Cells (total) | 6,117    |
| Wire bits     | 256,936  |
| `$mul` (256x256 multiplier instances) | 73 |
| FF (DFF + ADFF cells) | 138 |
| `$add` / `$sub` | 147 / 86 |

`scalar_mod_n` がシミュレーション用に `%` 演算子を含むため、`nostr_sign`
トップを LUT4 にマップすると `synth_xilinx` 系でエラーになります。
合成可能化は本格 mod n 乗算器への置換 (TODO 項目 2) が前提。
