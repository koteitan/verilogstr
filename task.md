# Nostr 署名 実現までの残り作業

README の「実装状況と課題」+ ソース確認から洗い出した TODO。
優先度は **1, 2, 5, 6 → 7 → 8** の順で詰めるのが最短。

## 必須（これが無いと正しい署名が出ない）

- [ ] **1. `ec_arith.v` の `ec_point_mul_g` 本実装**
  現状は入力スカラーをそのまま返すダミー。
  - secp256k1 の Jacobian 座標による点加算 / 点二倍
  - Double-and-add アルゴリズム (256 ビットスカラー → ~256 反復)
  - サイドチャネル対策 (一定時間化、Montgomery ladder 等)
  - mod p フィールド乗算器 (Montgomery 乗算)

- [ ] **2. `ec_arith.v` の `scalar_mod_n` 乗算**
  現状は `%` 演算子でシミュレーション用、合成不可。
  - Montgomery 乗算器に置換 (1 mul ≈ 256 サイクル)

- [ ] **3. 公開鍵 X 座標 `P.x` の取得経路**
  署名に必要な `P.x = (d*G).x` を取り出す。
  項目 1 の EC スカラー倍器を使い回す形になる想定。

- [ ] **4. `R.y` の偶奇判定**
  現状は R の X 座標しか扱っていない疑いあり。
  - Jacobian → affine 変換
  - y 偶奇判定して `k = k'` or `n - k'` を選択

- [ ] **5. タグ付きハッシュの定数埋め込み**
  `nostr_sign.v` の `TAG_AUX_PRE` / `TAG_NONCE_PRE` / `TAG_CHALLENGE_PRE` が
  プレースホルダ。
  - `SHA256("BIP0340/aux")` 等の実値 (midstate 形式) を計算して埋め込む

- [ ] **6. SHA-256 パディング任意長化**
  `build_block_1` / `build_block_2` が最大 119 バイト固定。
  Nostr の serialized event は容易に超える。
  - バレルシフタ式の任意長対応に書き換え

## 検証（必須）

- [ ] **7. BIP-340 公式テストベクタ通過**
  bip-0340.mediawiki の test vectors でビット完全一致を確認。

- [ ] **8. Nostr 実イベント署名 → relay 投入**
  - `id = SHA256(serialize(event))` を 32 バイトメッセージ m として 1〜7 を実行
  - `["EVENT", ...]` を relay に送って受理確認

## 周辺

- [ ] **9. Nostr イベント serialization**
  `[0, pubkey, created_at, kind, tags, content]` の決定的 JSON 化 → SHA256。
  これが署名対象 m。HW 内でやるか前段ソフトでやるか方針決め。

- [ ] **10. 鍵投入 I/F**
  秘密鍵 d、補助乱数 a、メッセージ m を外部から入れるバスを決める
  (SPI / AXI 等)。

- [ ] **11. `tb_nostr_sign.v` を実テストベクタに更新**
  現状 1〜6 のダミー前提のはず。BIP-340 ベクタに合わせる。
