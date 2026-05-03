# Nostr 署名 (BIP-340 Schnorr / secp256k1) Verilog 実装

version: v0.1

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
