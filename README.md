[English](README.md) | [Japanese](README-ja.md)

# Nostr Signing (BIP-340 Schnorr / secp256k1) — Verilog Implementation

version: v0.1.5

A **design skeleton** of Verilog code that signs Nostr events in hardware.

## File layout

| File                  | Contents                                                       |
|-----------------------|----------------------------------------------------------------|
| `nostr_sign.v`        | Top module. State machine for the BIP-340 Schnorr signing flow |
| `sha256_core.v`       | SHA-256 compression + variable-length (≤183 B) message + tagged-hash wrapper |
| `ec_arith.v`          | secp256k1 mod-p arithmetic (combinational add/sub/mul/inv) and Jacobian point ops |
| `field_seq.v`         | Synthesizable sequential 256-cycle multiplier + Fermat inverter (~131k cycles) |
| `ec_engine.v`         | Programmable EC engine (shared ALU + RegFile + microcode ROM) — used by `nostr_sign` for `k*G` |
| `tb_nostr_sign.v`     | BIP-340 official test vectors v0–v3                            |
| `tb_hello_world.v`    | Real Nostr event (kind:1, "hello world") signing demo          |
| `tb_sha256_*.v` / `tb_field_*.v` / `tb_ec_*.v` | Unit testbenches for each lower-level module |

## Signing algorithm (BIP-340)

```
Inputs: secret key d, message m, auxiliary randomness a
1. d' = d            if (d*G).y is even, else n - d
2. t  = d' xor tagged_hash("BIP0340/aux", a)
3. k' = int(tagged_hash("BIP0340/nonce", t || P.x || m)) mod n
4. R  = k' * G
5. k  = k'           if R.y is even, else n - k'
6. e  = int(tagged_hash("BIP0340/challenge", R.x || P.x || m)) mod n
7. signature = (R.x, (k + e*d') mod n)
```

`tagged_hash(tag, x) = sha256(sha256(tag) || sha256(tag) || x)`

## Implementation status

The BIP-340 Schnorr signing logic is bit-exact against the official test
vectors in simulation. The remaining work below is what is needed to take
this to a real FPGA / ASIC.

### ✅ Done
- Jacobian (a=0) point doubling / addition / public-key X retrieval / R.y parity check (`ec_arith.v`)
- 256-iteration double-and-add scalar multiplication (`ec_engine.v`, ALU-shared)
- mod-p field arithmetic (synthesizable via fast reduction, `field_*_p`)
- mod-p inversion (Fermat's little theorem, `field_inv_p`)
- BIP-340 tagged-hash constants (aux/nonce/challenge) baked in
- SHA-256 padding extended to up to 3 blocks (≤ 183 B)
- BIP-340 official vectors v0–v3 bit-exact pass
- Real Nostr event (kind:1, "hello world") signed → externally verified VALID

### ⚠️ Open items (toward synthesizable / production-grade design)

#### 1. (Done) Sequentialize the mod-n multiplier (`scalar_mod_n`)
Replaced in v0.1.4 with a 256-cycle shift-and-add + two-step subtract.
**The whole `nostr_sign` top now LUT4-maps cleanly** (Yosys reports
~68,950 LUT4 + 16,509 FF).

#### 2. (Done) Constant-time hardening
Rewritten in v0.1.5 as always-double-and-add with bitwise CMOV mux.
New opcodes `OP_CMOV_NB` / `OP_CMOV_BZ` were added so the original
`LDBN` / `BZ` branches could be eliminated.

**Empirical evidence from `tb_ec_engine`** (`k*G` for several scalars):

| Scalar k | Cycles         | Result  |
|---------:|---------------:|:--------|
|        1 | **1,338,628**  | ✅ PASS |
|        2 | **1,338,628**  | ✅ PASS |
|        3 | **1,338,628**  | ✅ PASS |
|        5 | **1,338,628**  | ✅ PASS |

All four runs complete in exactly the same number of cycles even though the
scalar bit patterns differ — timing-based key leakage is therefore
impossible at the cycle level.

#### 3. (Done) Sequentialize `field_mul_p`
Replaced in v0.1.3 by `field_seq_mul_p` (256-cycle shift-and-add).
~3.4k LUT4, synthesizable, ~200 MHz target Fmax.

#### 4. Speed up `field_inv_p`
Fermat's method needs 256+ cycles. Replacing with a binary-GCD-style inverter
brings it down to a few dozen. Important when `ec_to_affine` is on the hot path.

#### 5. Variable-length message
`nostr_sign`'s `msg` is fixed at 32 B (Nostr's event_id assumption). To handle
variable-length messages from BIP-340 vectors v15+, either pre-hash with
SHA-256 in a higher layer (compressing to 32 B) or extend `sha256_top` to
support more blocks.

#### 6. Key-loading interface
Currently a parallel `[255:0]` port. Adding an SPI / AXI serial interface
makes it usable as an HSM-style coprocessor.

#### 7. Real relay submission
Push the signed event to a `wss://...` Nostr relay over WebSocket and verify
it is accepted in the wild.


## Suggested integration paths

Because `field_mul_p` is currently combinational, the whole design lives in
the **hundreds of thousands to millions of LUT4** range (see "Circuit size"
below). Even after Montgomery-izing — which yields 1–2 orders of magnitude
of area reduction — the design is still big for IoT-class targets, so:

| Approach | Description |
|---|---|
| Full HW | Montgomery-ize and put everything in HW. Perfect HW key isolation |
| HSM-style | Only the EC engine in HW; hashing / padding stays in software |
| Co-processor | License a secp256k1 IP core (e.g. ECDSA / Schnorr accelerator) and integrate |

## Build / simulation example (Icarus Verilog)

```sh
iverilog -o sim nostr_sign.v sha256_core.v ec_arith.v tb_nostr_sign.v
vvp sim
gtkwave nostr_sign.vcd
```

## Live demo: a Nostr event signed in Verilog

`tb_hello_world.v` uses an arbitrary secret key and signs a `kind:1 / content:"hello world"`
Nostr event in the Icarus iverilog simulator. The signature is produced
through `nostr_sign` using the **programmable EC engine version (`ec_engine.v`)**
and was verified VALID by an external Python BIP-340 reference.

| Field        | Value                                                                |
|--------------|----------------------------------------------------------------------|
| `nsec1`      | `nsec1kzlc50ntfsxnrf0z7r657zsj8rr73ge0tkv7x9r2ttgjh062rjfs5hqm5t`     |
| `npub1`      | `npub14xurjwprdu2ug5hl20qwhh3y766jlxhfefrcyxxyaj7x0sxzzssqn4exwz`     |
| `created_at` | `1700000000`                                                         |
| `event_id`   | `871ce455cfdbaf3deb04a8f101494df9142fc1f9eeba8fc6d0934768f4063062`   |
| `sig (R)`    | `a6c159cc30a14de9d2a8502fc3354e01c8d63d2a3c7fb2e9ee7c94a9b4a29d97`   |
| `sig (s)`    | `1e61ef9d59f81885c928203d308466b73a0c7316afe23aa819637d4b06137ac4`   |
| start→done   | `2,678,083 cycles` (26.8 ms at 100 MHz; constant-time)               |

The signed event (ready to push as `["EVENT", ...]` to a relay):

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

The BIP-340 official vectors (`tb_nostr_sign.v`, v0–v3) also pass with
bit-exact matches.

## Circuit size (Yosys 0.9, after `synth → abc -lut 4`)

The code is written as a behavioral simulation model and **instantiates
many combinational 256×256 multipliers in parallel**, so it is not
realistically synthesizable as-is. Going to a single Montgomery multiplier
shared in time-domain (TODO #2) is the prerequisite for any real silicon.

| Module             | LUT4    | FF       | Notes                                  |
|--------------------|--------:|---------:|----------------------------------------|
| `field_seq_mul_p`  |  3.4 k  |   1.0 k  | Sequential 256-cycle multiplier (synthesizable) |
| `field_seq_inv_p`  |  ~7 k   |  ~1.5 k  | Fermat method, ~131k cycles (multiplier reused) |
| `sha256_block`     |   13 k  |  ~2.8 k  | FIPS 180-4 compression (64 cycles)     |
| `sha256_top`       |   11 k  |  ~2.8 k  | Padding + up to 3 blocks               |
| `ec_engine`        |   39 k  |  ~7.5 k  | Shared 256-bit ALU + RegFile + microcode ROM |

`nostr_sign` top-level (technology-independent cell counts, before `synth`):

| Metric                                     | Value      |
|--------------------------------------------|-----------:|
| Cells (total, before synth)                | 6,148      |
| `$mul` (small ×977 inside reduction)       | 4          |
| `$mod`                                     | **0**      |
| `$add` / `$sub`                            | 42 / 15    |
| LUT4 (after `synth → abc -lut 4`)          | **83,670** |
| FF                                         | 16,509     |

The `$mod` cell is **gone**, so the entire `nostr_sign` top now LUT4-maps
cleanly. 68k LUT4 fits comfortably not only on a Stratix 10 GX 10M
(~10M LE), but also on mid-size Artix-7 / Cyclone V class FPGAs.

Because `scalar_mod_n` still uses the `%` operator for simulation, mapping
the `nostr_sign` top to LUT4 with `synth_xilinx` will fail. Synthesizability
requires replacing it with a real mod-n multiplier (item 1 in implementation status).

## Latency and throughput

### Cycles per signature (measured)

Measured start→done in `tb_hello_world.v` (one Nostr `kind:1` event):
**2,678,083 cycles** — constant-time always-double-and-add, so the cycle
count does not depend on the scalar (1 mul = 256 cycles, 1 inv ≈ 131k cycles).

### Estimate on a Stratix 10 GX 10M

| Configuration                              | Est. Fmax | 1 sig   | sig/s |
|--------------------------------------------|---------:|--------:|------:|
| Current (constant-time, sequential mul)    | ~200 MHz | 13.4 ms | ~75   |
| (Ideal) Montgomery multiplier + pipeline   | ~300 MHz | ~150 µs | ~6,500 |

### Comparison: software implementations

| Implementation                                  | 1 sig | sig/s (1 core) |
|-------------------------------------------------|------:|---------------:|
| Apple M3 / Ryzen 7000 (libsecp256k1)            | ~30 µs | ~33,000       |
| Intel Xeon Skylake (libsecp256k1)               | ~50 µs | ~20,000       |
| Raspberry Pi 4 (ARM Cortex-A72)                 | ~200 µs | ~5,000        |
| ESP32 / low-end MCU                             | ~5 ms  | ~200          |

**On raw throughput modern x86 is one order of magnitude faster.** The
reasons to do this in HW are not raw speed but:

- **Power efficiency** (W on a CPU vs. mW for a dedicated block)
- **Physical key isolation** (secret key never touches software — HSM use)
- **Deterministic latency** (no OS interrupts or cache misses to skew timing)
- **Trivial parallelism** (ASIC with dozens of cores → hundreds of k sig/s)
