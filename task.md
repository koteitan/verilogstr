# Nostr 署名 実現までの残り作業

README の「実装状況と課題」+ ソース確認から洗い出した TODO。
優先度は **1, 2, 5, 6 → 7 → 8** の順で詰めるのが最短。

## 必須（これが無いと正しい署名が出ない）

- [x] **1. `ec_arith.v` の `ec_point_mul_g` 本実装**
  Jacobian 座標で double-and-add を実装 (256 反復)。
  field_add_p / field_sub_p / field_mul_p (高速 reduction) を新設。
  field_inv_p は Fermat (a^(p-2) mod p, ~257 サイクル) で実装。
  ec_point_dbl_jac / ec_point_add_jac は combinational。
  ec_to_affine で Jacobian → Affine 変換。
  サイドチャネル対策と Montgomery 乗算器化は将来課題。

- [~] **2. `ec_arith.v` の `scalar_mod_n` 乗算**
  シミュ用の `%` ベース実装のまま (合成不可)。
  シミュレーションでは BIP-340 ベクタ通過に支障なし。
  本格化 (Montgomery 乗算器) は将来課題。

- [x] **3. 公開鍵 X 座標 `P.x` の取得経路**
  ec_point_mul_g 改修で `rx` 出力として取得。

- [x] **4. `R.y` の偶奇判定**
  ec_to_affine で affine 化、`ry[0]` で偶奇判定済み。

- [x] **5. タグ付きハッシュの定数埋め込み**
  `nostr_sign.v` の `TAG_AUX_PRE` / `TAG_NONCE_PRE` / `TAG_CHALLENGE_PRE` に
  `sha256("BIP0340/aux")` 等の実値を埋め込み済 (2 回連結の 512bit)。

- [x] **6. SHA-256 パディング任意長化** (3 ブロック対応, ≦183B)
  `sha256_top` を 3 ブロック対応 (MAX_BYTES=192) に拡張。
  `tagged_sha256` も 192B 対応に拡張。
  境界テスト (64/96/119/120/160/183B) と BIP-340 nonce サイズ (160B total) で検証済。
  Nostr の長い event をハッシュするにはさらにブロック数拡張が必要 (将来課題)。

## 検証（必須）

- [x] **7. BIP-340 公式テストベクタ通過**
  v0〜v3 (sk=3, sk_random, sk_pi, sk_with_max_aux_msg) でビット完全一致を確認。
  v15 以降 (任意長 msg) は項目 9 の入力 I/F 拡張が必要。

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

- [x] **11. `tb_nostr_sign.v` を実テストベクタに更新**
  BIP-340 公式 v0〜v3 をそのまま流して全 PASS。
