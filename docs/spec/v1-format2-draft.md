# Mass Asset v1 (format 2) — Specification

**Status:** **v1.0** — released and deployed immutable on X1 mainnet as `MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp` (finalized 2026-11-17; release evidence in `evidence/`). Self-contained. The text is draft 5 unchanged apart from this header and the program id in §0.1–0.2; the file keeps its name because the program sources refer to it.
**Date:** 2026-11-17 (v1.0; draft 5 of 2026-11-15)
**Network:** X1 (SVM)

This document is normative on its own. It does not rely on the format-1 specification. The key words **MUST**, **MUST NOT**, **SHOULD** and **MAY** are to be interpreted as described in RFC 2119.

---

## 0. Formats and constants

### 0.1 Mapping

| Program id | Status | `version` | `HEADER_LEN` | Object seed | Authority seed |
|---|---|---:|---:|---|---|
| `MAssPQXuBXvvf196oXKFZ1GiC9kTsJJ8podQV3m72Wv` | format 1, "v0.1 preview", superseded, not for use | 1 | 72 | `mass-asset` | `mass-asset-authority` |
| `MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp` | **format 2, Mass Asset v1** (this document), immutable | 2 | 104 | `ma1-asset` | `mass-asset-authority` |

- An integrator identifies a format by the **pair** (account owner program id, `version`), never by `version` or by field offsets alone.
- Different program ids already give disjoint PDA address spaces; the distinct object seed and `version` make the separation explicit.
- Both formats share the issuer authority PDA (§2.1). No issuer is expected to use format 1.

### 0.2 Constants of format 2

| Name | Value |
|---|---|
| `MASS_ASSET_PROGRAM_ID` | `MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp` (X1 mainnet) |
| `VERSION` | `2` |
| `HEADER_LEN` | `104` |
| `MAX_PAYLOAD` | `1024` |
| `OBJECT_SEED` | the bytes `ma1-asset` |
| `AUTHORITY_SEED` | the bytes `mass-asset-authority` |
| `SYSTEM_PROGRAM_ID` | `11111111111111111111111111111111` |
| `LOADER_V3_ID` | `BPFLoaderUpgradeab1e11111111111111111111111` |
| `ERROR_BASE` | `0x4D41_0000` |
| `EVENT_DOMAIN` | the bytes `ma1` |

`authority(ns)` below means the canonical issuer authority: `create_program_address([AUTHORITY_SEED, [object.authority_bump]], ns)` for an existing asset, or `find_program_address([AUTHORITY_SEED], ns)` at `create`.

---

## 1. Purpose and scope

Mass Asset is a minimal on-chain asset standard for X1. Every asset:

- belongs to exactly one **issuer**: a program, called the *namespace*;
- has exactly one **owner**, and at most one **delegate** that may transfer it once;
- carries a **payload**: bytes that only the issuer can write;
- is fully closed when it is consumed, and its rent is returned to the owner.

Not defined: N→M transitions, provenance, a persistent logical identity, proof of historical issuance after close.

**Identity.** The identity of an asset is the address of its account while that account is live. After close, the issuer can create a new asset at the same address if it reuses the `seed`. Issuers of value-backed tradable assets MUST NOT reuse a seed (E7).

## 2. Roles and trust

| Role | Who | How it is established |
|---|---|---|
| Issuer (namespace) | a program | the `namespace` field |
| Issuer authority | `authority(namespace)` | a signature, which only the issuer program can produce via `invoke_signed` |
| Owner | any `Pubkey` except `default`, the asset's own address, the Mass Asset program, the issuer program and the issuer authority | the `owner` field; a valid signature of that key in the current invocation |
| Delegate | `default` (no delegate), or any key allowed by D6 | set by the owner with `approve`; cleared by every `transfer` and by `revoke` |
| Payer | any valid signer of the current invocation | pays rent at `create` and `resize`; gains no rights over the asset |

**Signatures.** "Signed by K" means `account.is_signer` is true for the account with key K in the current instruction. This includes a PDA that signed through `invoke_signed` in the calling program. Mass Asset does not distinguish wallets from PDAs. An issuer that requires a wallet signature specifically MUST enforce that itself.

### 2.1 Issuer authority

- The authority seed is fixed forever: `AUTHORITY_SEED`, with no suffix.
- At `create` the authority is derived by the canonical search and its bump is stored in the header (`authority_bump`).
- For every later operation the authority MUST be derived only from `object.namespace` and `object.authority_bump`, using `create_program_address`. It MUST NOT be taken from instruction data or from a supplied account.
- `authority_bump` is written only by `create`.
- **Mass Asset never passes the authority account into any CPI** (I11). This is a guarantee about Mass Asset's own actions; what the issuer does with its authority is governed by E1.
- The same PDA is the authority for format 1. Its protection rests on E1: the issuer signs with it only for calls to a verified Mass Asset program id and never passes it to another program.

### 2.2 Trust in the issuer

The issuer is fully trusted. `owner` mode does not protect the value of an asset from its issuer. The issuer can always:

- consume the asset (the rent goes to the current owner);
- rewrite the payload and grow it;
- create a new asset at the same address after close (unless it follows E7).

In `owner` mode, being the issuer gives **no** right to transfer: the issuer program and its authority cannot be the owner (C7, T5) or the delegate (D6), and `transfer` accepts only the owner or the delegate. The owner can still explicitly approve any other key as delegate, including another PDA of the issuer program. That is the owner's choice.

An upgradeable issuer can change its own logic after issuance. Marketplaces and indexers MUST evaluate an asset together with the trust model of its issuer.

### 2.3 Owner requirements

To be consumable, an owner needs to be able to receive lamports as a writable, non-executable account. On X1, closing an asset whose owner is an executable account fails with `ExternalAccountLamportSpend`. Mass Asset rejects the asset itself, the Mass Asset program, the issuer program and the issuer authority as owner. Any other unsuitable address is the responsibility of the issuer at `create` and of the holder at their own `transfer`.

### 2.4 Owner or delegate that is a PDA

Only the PDA's program can sign for it.

- Programs that hold Mass Assets MUST be able to invoke `transfer`, `approve`, `revoke` and `orphan_close` for them.
- If such a program is closed or cannot make the call, every action that needs the owner's signature (`transfer`, `approve`, `revoke`, `orphan_close`, and issuer actions under R2) is blocked, exactly as for an owner who lost their key. Issuer-only `consume` and permissionless payouts under R7 follow their own rules.
- `orphan_close` returns all lamports in the asset account, including any excess above rent (I8). Value held in the issuer's vaults is outside this operation.
- A program whose PDA is used as a delegate (for example a marketplace listing PDA) MUST NOT expose instructions that sign arbitrary CPIs with that PDA (§8.2).

## 3. Asset account

### 3.1 Address

```text
object = find_program_address([OBJECT_SEED, namespace, seed], MASS_ASSET_PROGRAM_ID)
```

- `seed` is 32 bytes chosen by the issuer.
- Only the canonical bump is accepted. A caller-supplied bump is never accepted.
- The object bump and `seed` are not stored. An issuer that needs them stores them in the payload.

### 3.2 Layout (little-endian)

| Offset | Size | Field | Rule |
|---:|---:|---|---|
| 0 | 1 | `version` | `= 2` |
| 1 | 1 | `flags` | bits 0–1 = `transfer_mode`; bits 2–7 MUST be 0 |
| 2 | 2 | `payload_len` | `u16`, `0 ≤ payload_len ≤ 1024` |
| 4 | 32 | `namespace` | issuer program |
| 36 | 32 | `owner` | current owner |
| 68 | 32 | `delegate` | all zeros (`default`) = no delegate |
| 100 | 1 | `authority_bump` | canonical bump of `authority(namespace)`; written only by `create` |
| 101 | 3 | `reserved` | MUST be 0 |
| 104 | `payload_len` | `payload` | issuer bytes; starts 8-byte aligned |

- The account size is `104 + payload_len`. It changes only through `resize`, and only upward.

`transfer_mode`:

| Value | Name | Who can transfer |
|---:|---|---|
| 0 | `owner` | the owner, or the delegate if one is set |
| 1 | `namespace` | only the issuer authority |
| 2 | `frozen` | nobody |
| 3 | — | invalid |

**For indexers:** `getProgramAccounts` on `MASS_ASSET_PROGRAM_ID` with a memcmp filter at offset 0 (`version = 2`) plus offset 4 (`namespace`), 36 (`owner`) or 68 (`delegate`). The filters help searching; an account is an asset of this format only if it passes `validate`.

### 3.3 `validate(object)` — in exactly this order

| # | Check | Error |
|---|---|---|
| V1 | `object.owner == MASS_ASSET_PROGRAM_ID` | `NotMassAsset` |
| V2 | `data_len ≥ 104` | `InvalidAccountSize` |
| V3 | `version == 2` | `UnsupportedVersion` |
| V4 | `flags & 0xFC == 0` and `transfer_mode ≠ 3` | `InvalidFlags` |
| V5 | `reserved == [0, 0, 0]` | `InvalidHeader` |
| V6 | `payload_len ≤ 1024` and `data_len == 104 + payload_len` | `InvalidAccountSize` |
| V7 | `owner ≠ default` | `InvalidOwner` |
| V8 | if `transfer_mode ≠ owner` then `delegate == default` | `InvalidHeader` |

### 3.4 `require_authority(signer, header)`

| # | Check | Error |
|---|---|---|
| A1 | `signer.is_signer` | `InvalidAuthority` |
| A2 | `create_program_address([AUTHORITY_SEED, [authority_bump]], namespace) == signer.key` | `InvalidAuthority` |

The cost is one `create_program_address` for every issuer.

---

## 4. Instructions

The first byte of instruction data is the tag. `data` means the bytes after the tag; `len(data)` is their length. Accounts are listed in a fixed order; extra accounts are ignored. The "readonly" marks are for clients; the program does not check them.

**Order of execution:**

1. All data checks: C1–C5, T1, W1, K1, O1, D1, X1, Z1–Z2.
2. Account reads. If accounts are missing, the built-in error `NotEnoughAccountKeys` is returned here.
3. The remaining rows of the table, in order.
4. State changes, then exactly one event (§7). A failed instruction changes nothing and emits no event.

| Tag | Instruction | Signed by |
|---:|---|---|
| 0 | `create` | issuer authority + payer |
| 1 | `transfer` | owner or delegate (`owner` mode); issuer authority (`namespace` mode) |
| 2 | `write_payload` | issuer authority |
| 3 | `consume` | issuer authority |
| 4 | `orphan_close` | owner |
| 5 | `approve` | owner |
| 6 | `revoke` | owner or delegate |
| 7 | `resize` | issuer authority + payer |

Tags 8–255 and a missing tag return `InvalidInstruction`.

### 4.0 `create` — tag 0

Data:

```text
seed[32] | transfer_mode u8 | payload_len u16 | owner[32] | payload[payload_len]
```

Accounts:

| # | Account | Properties |
|---:|---|---|
| 0 | `authority` | signer |
| 1 | `namespace` | readonly |
| 2 | `payer` | signer, writable |
| 3 | `object` | writable |
| 4 | `system_program` | |

| # | Check | Error |
|---|---|---|
| C1 | `len(data) ≥ 67` | `InvalidInstruction` |
| C2 | `transfer_mode ≤ 2` | `InvalidFlags` |
| C3 | `payload_len ≤ 1024` | `InvalidAccountSize` |
| C4 | `len(data) == 67 + payload_len` | `InvalidInstruction` |
| C5 | `owner ≠ default` | `InvalidOwner` |
| C6 | `authority`, `namespace`, `payer`, `object` are pairwise distinct | `DuplicateAccount` |
| C7 | `owner ∉ {object, MASS_ASSET_PROGRAM_ID, namespace, authority(namespace)}`; the authority is derived here by `find_program_address` and reused in C8 | `InvalidOwner` |
| C8 | `authority.is_signer` and `authority.key == find_program_address([AUTHORITY_SEED], namespace).0` | `InvalidAuthority` |
| C9 | `payer.is_signer` | `MissingSigner` |
| C10 | `payer` and `object` are writable | `AccountNotWritable` |
| C11 | `system_program == SYSTEM_PROGRAM_ID` | `InvalidSystemProgram` |
| C12 | `object == find_program_address([OBJECT_SEED, namespace, seed], MASS_ASSET_PROGRAM_ID).0` | `InvalidObjectAddress` |
| C13 | address state (below) is *empty* or *pre-funded* | `ObjectAddressInUse` |
| C14 | *empty*: `payer.lamports ≥ rent(104 + payload_len)`; *pre-funded* with `current < rent(104 + payload_len)`: `payer.lamports ≥ rent − current`; not checked when `current ≥ rent` | `InsufficientFunds` |

Address states:

- **Empty:** 0 lamports. Mass Asset calls System `create_account` (payer → object, `space = 104 + payload_len`, owner = Mass Asset) via `invoke_signed` with the object seeds.
- **Pre-funded:** owner = System, `data_len == 0`, lamports > 0. Mass Asset (1) transfers the shortfall from `payer` if any, (2) calls `allocate` and (3) `assign` via `invoke_signed` with the object seeds. Excess lamports stay in the account and go to the owner on close.
- **Any other state:** `ObjectAddressInUse`.

Then the header is written: `version = 2`, `flags = transfer_mode`, `payload_len`, `namespace`, `owner`, `delegate = default`, `authority_bump`, `reserved = 0`, followed by the payload.

Notes:

- C6 rules out `payer == authority`. Otherwise the authority signature, passed into the System CPI, would let lamports be debited from the authority PDA.
- The System CPIs receive only `payer`, `object` and `system_program`, never the authority (I11).
- No check of `namespace.executable`: C8 already proves that the issuer program is executing.
- Paths unreachable on a correct runtime: after the CPIs Mass Asset checks `object.owner == MASS_ASSET_PROGRAM_ID` and the size, else `InvalidAccountSize`. Errors from the System Program (for example a payer not owned by System) are returned as they are, without `ERROR_BASE`.

Event: `Create`.

### 4.1 `transfer` — tag 1

Data: `new_owner[32]`. Accounts: 0 `object` (writable), 1 `signer` (signer).

| # | Check | Error |
|---|---|---|
| T1 | `len(data) == 32` | `InvalidInstruction` |
| T2 | `object` is writable | `AccountNotWritable` |
| T3 | `validate(object)` | §3.3 |
| T4 | mode `owner`: `signer.is_signer` and (`signer.key == owner` or (`delegate ≠ default` and `signer.key == delegate`)) | `InvalidAuthority` |
| | mode `namespace`: `require_authority(signer)` | `InvalidAuthority` |
| | mode `frozen` | `TransferDisabled` |
| T5 | `new_owner ∉ {default, object, MASS_ASSET_PROGRAM_ID, namespace, authority(namespace)}` | `InvalidOwner` |

Effect: `owner = new_owner`; `delegate = default`. This holds for every transfer, including one signed by the owner and one to the current owner.

A delegate can transfer to any key allowed by T5, including itself. Mass Asset does not know the terms of a sale; a marketplace enforces them (§8.2).

Event: `Transfer`, `by` = 0 owner, 1 delegate, 2 authority. If the signer is both owner and delegate (impossible by D6), `by = 0`.

### 4.2 `write_payload` — tag 2

Data: `offset u16 | bytes[..]`. Accounts: 0 `object` (writable), 1 `authority` (signer).

| # | Check | Error |
|---|---|---|
| W1 | `len(data) ≥ 2` | `InvalidInstruction` |
| W2 | `object` is writable | `AccountNotWritable` |
| W3 | `validate(object)` | §3.3 |
| W4 | `require_authority(authority)` | `InvalidAuthority` |
| W5 | `offset + len(bytes) ≤ payload_len` (checked arithmetic) | `PayloadOutOfBounds` |

Effect: payload bytes `[offset, offset + len)` are overwritten. The header cannot be written. The delegate is not changed. An empty write is valid.

Event: `WritePayload`.

### 4.3 `consume` — tag 3

Data: none. Accounts: 0 `object` (writable), 1 `authority` (signer), 2 `owner_account` (writable).

| # | Check | Error |
|---|---|---|
| K1 | `len(data) == 0` | `InvalidInstruction` |
| K2 | `object` and `owner_account` are writable | `AccountNotWritable` |
| K3 | `validate(object)` | §3.3 |
| K4 | `require_authority(authority)` | `InvalidAuthority` |
| K5 | `owner_account.key == object.owner` | `RefundMismatch` |
| K6 | `owner_account.key ≠ object.key` | `DuplicateAccount` |

Effect — **hard close**:

1. if `owner_account.lamports + object.lamports` overflows u64, fail with `ArithmeticOverflow` before any change;
2. zero the data;
3. resize the account to 0;
4. move all lamports to `owner_account`;
5. assign the account to the System Program.

The delegate has no part in `consume`. Event: `Close`, `reason = 0`.

### 4.4 `orphan_close` — tag 4

Data: none. Accounts: 0 `object` (writable), 1 `owner` (signer, writable), 2 `namespace` (readonly), 3 `namespace_programdata` (readonly).

| # | Check | Error |
|---|---|---|
| O1 | `len(data) == 0` | `InvalidInstruction` |
| O2 | `object` and `owner` are writable | `AccountNotWritable` |
| O3 | `validate(object)` | §3.3 |
| O4 | `owner.is_signer` and `owner.key == object.owner` | `InvalidAuthority` |
| O5 | `namespace.key == object.namespace` | `NamespaceMismatch` |
| O6 | `namespace_absent(namespace, namespace_programdata)` | `NamespaceAlive` |

```text
namespace_absent(ns, pd) :=
      ns.owner == LOADER_V3_ID
  AND ns.data.len() >= 36
  AND u32_le(ns.data[0..4]) == 2            // UpgradeableLoaderState::Program
  AND pd.key == Pubkey(ns.data[4..36])      // programdata_address
  AND pd.owner != LOADER_V3_ID
```

Effect: hard close as in §4.3 (including the overflow guard); lamports go to `owner`. The delegate cannot call `orphan_close`.

- The check is on the owner of the ProgramData account, not on its lamports (Appendix A.2).
- Only issuers under the upgradeable loader (loader-v3) can ever be absent. An issuer under any other loader, including loader-v4, is never absent for this program. Support for another loader requires a new program id.

Event: `Close`, `reason = 1`.

### 4.5 `approve` — tag 5

Data: `delegate[32]`. Accounts: 0 `object` (writable), 1 `owner` (signer).

| # | Check | Error |
|---|---|---|
| D1 | `len(data) == 32` | `InvalidInstruction` |
| D2 | `object` is writable | `AccountNotWritable` |
| D3 | `validate(object)` | §3.3 |
| D4 | `transfer_mode == owner` | `DelegationNotAllowed` |
| D5 | `owner.is_signer` and `owner.key == object.owner` | `InvalidAuthority` |
| D6 | `delegate ∉ {default, object.owner, object, MASS_ASSET_PROGRAM_ID, namespace, authority(namespace)}` | `InvalidDelegate` |

Effect: `delegate = new delegate`, replacing any previous delegate.

The delegate gets the right to **one transfer** to any key allowed by T5, and the right to revoke itself (§4.6). Nothing else: no payload, no close, no further approval. Because the authority seed is shared with format 1, D6 excludes the issuer authority of both formats with one check.

Event: `Approve`.

### 4.6 `revoke` — tag 6

Data: none. Accounts: 0 `object` (writable), 1 `signer` (signer).

| # | Check | Error |
|---|---|---|
| X1 | `len(data) == 0` | `InvalidInstruction` |
| X2 | `object` is writable | `AccountNotWritable` |
| X3 | `validate(object)` | §3.3 |
| X4 | `signer.is_signer` and (`signer.key == owner` or (`delegate ≠ default` and `signer.key == delegate`)) | `InvalidAuthority` |

Effect: `delegate = default`. Succeeds when no delegate is set (owner signer; idempotent). The delegate may revoke itself, so a marketplace can cancel or expire its listing.

Event: `Revoke`, `by` = 0 owner, 1 delegate; `previous` = the delegate before the call (may be `default`).

### 4.7 `resize` — tag 7

Data: `new_payload_len u16`. Accounts:

| # | Account | Properties |
|---:|---|---|
| 0 | `object` | writable |
| 1 | `authority` | signer |
| 2 | `payer` | signer, writable |
| 3 | `system_program` | |

| # | Check | Error |
|---|---|---|
| Z1 | `len(data) == 2` | `InvalidInstruction` |
| Z2 | `new_payload_len ≤ 1024` | `InvalidAccountSize` |
| Z3 | `object`, `authority`, `payer` are pairwise distinct | `DuplicateAccount` |
| Z4 | `object` and `payer` are writable | `AccountNotWritable` |
| Z5 | `validate(object)` | §3.3 |
| Z6 | `require_authority(authority)` | `InvalidAuthority` |
| Z7 | `new_payload_len > payload_len` | `InvalidAccountSize` |
| Z8 | `payer.is_signer` (a wallet, or a PDA that signed through `invoke_signed`) | `MissingSigner` |
| Z9 | `system_program == SYSTEM_PROGRAM_ID` | `InvalidSystemProgram` |
| Z10 | `payer.lamports ≥ shortfall`, where `shortfall = max(0, rent(104 + new_payload_len) − object.lamports)` | `InsufficientFunds` |

Effect:

1. if `shortfall > 0`: System `transfer` of `shortfall` from `payer` to `object`. The CPI receives `payer`, `object` and `system_program` and no seeds; `payer` signs with the signature it has in the current invocation. A System Program error (for example a payer not owned by System, or one that holds data) is returned as it is. If `shortfall == 0` there is no CPI and excess lamports stay in the asset;
2. grow the account to `104 + new_payload_len`; existing bytes are kept and the new bytes are zero;
3. `payload_len = new_payload_len`.

Shrinking is not supported. The largest asset is 1,128 bytes, well within the runtime's per-instruction growth limit (10,240 bytes).

Event: `Resize` with `topup = shortfall`.

---

## 5. Invariants

| ID | Invariant |
|---|---|
| I1 | Every asset created by a successful `create` of this program and not yet closed passes `validate`. (Anyone can make some other account owned by Mass Asset through the System Program; such an account contains only zero bytes, possibly with a non-zero size, fails `validate` and is rejected by every instruction) |
| I2 | `namespace` equals the program whose canonical authority signed `create`; `authority_bump` is that authority's canonical bump; both are immutable |
| I3 | `version`, `flags`, `namespace`, `authority_bump` and `reserved` never change. `payload_len` and the account size change only through `resize`, only upward |
| I4 | Only the issuer authority can change the payload or its length |
| I5 | Only the party allowed by `transfer_mode` can change `owner`; in `owner` mode that is the owner or the current delegate; in `frozen` mode nobody |
| I6 | `owner` is never `default`, the asset itself, the Mass Asset program, the issuer program or the issuer authority |
| I7 | `delegate` is `default` or a key allowed by D6; it is non-default only in `owner` mode; every `transfer` sets it to `default` |
| I8 | An asset can be closed only by `consume` (issuer authority) or `orphan_close` (owner, issuer absent). On close all lamports go to the current owner |
| I9 | After close the address is deleted by the runtime or is a System-owned shell with zero data; it is not an asset until a new `create` |
| I10 | Every successful instruction emits exactly one event, after all state changes |
| I11 | Mass Asset passes the issuer authority account into no CPI |
| I12 | Mass Asset owns no shared accounts. Write locks still apply to payer, owner and delegate accounts |

## 6. Issuer obligations (normative)

| ID | Rule |
|---|---|
| E1 | The PDA `[AUTHORITY_SEED]` of the issuer is used **only** as the Mass Asset authority. It MUST NOT hold tokens, lamports or data, MUST NOT be set as an owner or delegate, and MUST NOT be passed as a signer to any program other than Mass Asset. Before every `invoke_signed` with the authority seeds, the issuer MUST check that the instruction's program id is a Mass Asset program id hard-coded in the issuer |
| E2 | The issuer MUST NOT derive any other PDA whose concatenated seeds equal `mass-asset-authority` (for example `["mass-asset-", "authority"]`). User-supplied data MUST NOT enter seeds the issuer signs with, unless a prefix rules out such a collision |
| E3 | The issuer MUST hard-code its authority bump as a constant (computed offline, checked by a test) and not call `find_program_address` at runtime |
| E4 | The test issuer in `tests/onchain/test-issuer` is a signing proxy for tests. It violates E1 and MUST NOT be used as a template |
| E5 | The issuer MUST NOT treat the delegate as having any right over the asset's value. Payouts and redemption follow `owner` only |
| E6 | An issuer that uses `resize` MUST handle every payload length it has ever issued; old assets are not grown automatically |
| E7 | An issuer of value-backed assets that can be traded MUST NOT reuse a `seed` for a new asset |

## 7. Events

### 7.1 Encoding

Each successful instruction calls `sol_log_data` once. The record has a fixed number of segments; every field is its own segment; integers are little-endian; keys are 32 raw bytes.

| Tag | Event | Segments (in order) | Count |
|---:|---|---|---:|
| 0 | `Create` | domain, tag, object, namespace, owner, transfer_mode u8, payload_len u16 | 7 |
| 1 | `Transfer` | domain, tag, object, from, to, by u8 | 6 |
| 2 | `WritePayload` | domain, tag, object, offset u16, len u16 | 5 |
| 3 | `Close` | domain, tag, object, owner, lamports u64, reason u8 | 6 |
| 4 | `Approve` | domain, tag, object, owner, delegate | 5 |
| 5 | `Revoke` | domain, tag, object, by u8, previous | 5 |
| 6 | `Resize` | domain, tag, object, old_len u16, new_len u16, topup u64 | 6 |

`domain` is the 3 bytes `ma1`; `tag` is 1 byte. Value sets: `Transfer.by` ∈ {0 owner, 1 delegate, 2 authority}; `Revoke.by` ∈ {0 owner, 1 delegate}; `Close.reason` ∈ {0 consume, 1 orphan}; `transfer_mode` ∈ {0, 1, 2}. A consumer MUST treat a record with an unknown tag, a wrong segment count, a wrong segment size or an unknown value as malformed and ignore it.

`Close.lamports` is the amount moved to the owner.

### 7.2 Reference encodings

`sol_log_data` prints `Program data:` followed by each segment in base64. In the examples, `K1` = 32 bytes of `0x01`, `K2` = 32 × `0x02`, and so on.

| Event | Values | Log line |
|---|---|---|
| Create | object K1, namespace K2, owner K3, mode 0, len 48 | `Program data: bWEx AA== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI= AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM= AA== MAA=` |
| Transfer | K1, from K3, to K4, by 1 | `Program data: bWEx AQ== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM= BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ= AQ==` |
| WritePayload | K1, offset 8, len 16 | `Program data: bWEx Ag== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= CAA= EAA=` |
| Close | K1, owner K4, 1,948,800 lamports, reason 0 | `Program data: bWEx Aw== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ= gLwdAAAAAAA= AA==` |
| Approve | K1, owner K3, delegate K5 | `Program data: bWEx BA== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM= BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU=` |
| Revoke | K1, by 0, previous K5 | `Program data: bWEx BQ== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AA== BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU=` |
| Resize | K1, 48 → 64, topup 111,360 | `Program data: bWEx Bg== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= MAA= QAA= ALMBAAAAAAA=` |

### 7.3 Rules for consumers

Events are informative. The account state is the only source of truth. A consumer MUST accept a record only if all of the following hold:

1. the transaction succeeded (`meta.err == null`);
2. the `Program data:` line was printed while the innermost open invocation frame was the exact `MASS_ASSET_PROGRAM_ID` (not inside a child invocation of another program), and that frame ended with `Program <MASS_ASSET_PROGRAM_ID> success`;
3. the record is well-formed (§7.1).

If the log is truncated, or the invocation stack cannot be reconstructed consistently, the record does not confirm a change. A persistent index MUST define its finality policy (for example `finalized` commitment) and reconcile with account state.

## 8. Integration rules for value-backed assets (normative for such issuers)

These rules apply when an asset represents value held elsewhere by the issuer, for example tokens in a vault paid out on redemption.

### 8.1 Issuer rules

| ID | Rule |
|---|---|
| R1 | Before reading the payload, the issuer MUST check: `object.owner` is a Mass Asset program id it supports, `version` is the matching format number (`2` for this program), `namespace` equals its own program id, the expected `payload_len`, and then the payload's own version, flags and field invariants |
| R2 | Every owner-initiated action that moves value (redemption, changing the terms of the position) MUST require the signature of the **current** `object.owner`, read from the account at execution time |
| R3 | The issuer MUST pay tokens only as follows. The token program id MUST be a constant in the issuer's code. The mint MUST be a constant or issuer state. The recipient account MUST be owned by that token program, with valid parsed state, the expected mint, and token owner = the current `object.owner`. The recipient MUST differ from the source vault. The payout MUST be a CPI into that token program |
| R4 | Redemption: in the same instruction the issuer MUST read the payload, settle the position and call `consume` on the same `AccountInfo`. Settling means paying out the position's value to the current `object.owner`; a part that cannot be paid at that moment (for example, rewards while the issuer's payouts are paused) MAY instead be recorded in issuer state as a standalone claim of the current owner, outside the object, which the issuer pays later by the same R3 rules. The object MUST NOT outlive the settlement, and the recorded claim MUST NOT depend on the closed object |
| R5 | The issuer MUST NOT hold a `RefCell` borrow of the object data across a CPI |
| R6 | The issuer MUST NOT rely on a separate owner → asset map: it goes stale after `transfer` |
| R7 | The issuer MAY allow anyone to trigger the payout of **already accrued** rewards to the current owner, without the owner's signature. Then: (a) the recipient MUST be determined by a rule fixed by the issuer, not chosen by the caller (for example: the associated token account of `object.owner` for the reward mint), and MUST satisfy R3; (b) the call MUST NOT change any other term of the position (rate, redemption date, principal) and MUST NOT redeem; (c) the accrual MUST keep the fractional remainder, so that the frequency of calls never reduces the owner's total reward |

### 8.2 Secondary markets

**Listing without escrow (normative for marketplaces that use delegates):**

- Each listing has its own identifier and its own listing PDA, derived from that identifier. A new listing always gets a new identifier and a new PDA; identifiers are never reused.
- The listing record binds: the Mass Asset program id and format, the asset address, the issuer (`namespace`), the seller (the owner at listing time), the listing PDA, and the terms (payment mint, amount, price-relevant payload bounds).
- The seller lists by calling `approve` with the listing PDA. The asset stays with the seller.
- The listing PDA signs only `transfer` and `revoke` for its own listing. It MUST NOT sign arbitrary CPIs.

**Sale, in one marketplace instruction:**

1. **Listing and buyer.** Check that the listing record is authentic (owned by the marketplace program, at its derived address) and active, and that it is bound to this asset, program id, format, issuer, seller and listing PDA. Check `owner == listing.seller` and `delegate == listing PDA` **before** calling the issuer. Check that the buyer signed this purchase, including the payment mint, the amount and the account that will receive the asset.
2. **Settle rewards.** Settle the seller's accrued rewards through the verified issuer (R7) to the seller's account fixed by the issuer's rule. The seller, still the owner, receives every whole minimal unit accrued up to this moment; a fractional remainder below one unit stays in the position and passes to the buyer. If a required settlement fails, the sale fails.
3. **Re-read the asset.** Check again `owner == listing.seller`, `delegate == listing PDA`, and the terms the buyer accepted (for example the principal and the redemption date).
4. **Payment.** Transfer the payment from the buyer's authorised account to the seller's verified account: check the token program, the mint and the amount. If the payment mint can charge a transfer fee, the listing MUST state which amount the seller receives, and the marketplace MUST check that the seller's account was credited with that amount (balance difference).
5. **Transfer and close.** `transfer` the asset to the buyer, signed by the listing PDA as delegate (the delegate is cleared), and close the listing record. If the payment path could change any checked field of the position, check those fields again immediately before the transfer.

Any failure reverts the whole instruction.

**Cancel:**

- **Through the marketplace:** one instruction closes the listing record and calls `revoke` signed by the listing PDA. Cancelling an active listing MUST require the seller's signature or a condition fixed in the listing (for example expiry).
- **Directly in Mass Asset:** the seller's `revoke`, or any `transfer`, clears the delegate. This disables execution only while the listing PDA is not the delegate. The marketplace's record may stay open; if the owner later calls `approve` directly for the same PDA, that open record becomes executable again. Cancellation is final only once the marketplace has closed the record. A new listing through the marketplace always gets a new id and PDA.

**Other rules:**

- If the asset is closed and a new one is created at the same address (which E7 forbids for value-backed tradable assets), the new asset has no delegate. A listing record that the marketplace has closed can never execute again; an open record is bound to the old seller and terms and is checked in step 1.
- If an escrow PDA is the owner instead, redemption pays both rent and value to the escrow, which must handle them.
- A namespace is permanent. An issuer cannot move its assets to a new program id: it upgrades in place, or its holders rely on `orphan_close` after the issuer program is closed.

## 9. Errors

Every Mass Asset error is `ProgramError::Custom(ERROR_BASE + code)`.

| Code | Name |
|---:|---|
| 0 | `InvalidInstruction` |
| 1 | `UnsupportedVersion` |
| 2 | `InvalidFlags` |
| 3 | `InvalidAccountSize` |
| 4 | `InvalidAuthority` |
| 5 | *(unassigned; never used)* |
| 6 | `InvalidObjectAddress` |
| 7 | `ObjectAddressInUse` |
| 8 | `InvalidOwner` |
| 9 | `TransferDisabled` |
| 10 | `PayloadOutOfBounds` |
| 11 | `RefundMismatch` |
| 12 | `NamespaceAlive` |
| 13 | `DuplicateAccount` |
| 14 | `ArithmeticOverflow` |
| 15 | `NotMassAsset` |
| 16 | `AccountNotWritable` |
| 17 | `NamespaceMismatch` |
| 18 | `InsufficientFunds` |
| 19 | `InvalidHeader` |
| 20 | `MissingSigner` |
| 21 | `InvalidSystemProgram` |
| 22 | `InvalidDelegate` |
| 23 | `DelegationNotAllowed` |

Built-in errors Mass Asset can also return: `NotEnoughAccountKeys`, account borrow errors, and System Program errors from its CPIs (without `ERROR_BASE`).

## 10. Operations and external assumptions

- **Runtime rules.** Rent return, hard close and `namespace_absent` rely on the current X1/SVM rules: closing a loader-v3 program deletes its ProgramData, and a closed program id cannot be redeployed. These are assumptions about the runtime.
- **Fees.** On X1 the fee is charged for the requested CU limit. Clients MUST simulate immediately before sending and set the limit to the simulated value plus a margin (recommended: `create` and `resize` +8,000, others +2,000).
- **CPI depth.** `create` and `resize` use two stack levels (Mass Asset, System). The current Agave limit is a stack height of 5; SIMD-0268 (raising it) is inactive on X1 mainnet and testnet as of 2026-11-15.
- **Loader-v4** is inactive on X1 mainnet and testnet (SIMD-0167). On testnet the `LoaderV4…` program account exists (owned by the native loader); on mainnet it does not. `namespace_absent` checks only loader-v3 ownership, so this does not change its result.
- **Measured CU (testnet, preview v0.2):** `transfer` (owner) 3,374; `transfer` (namespace) 4,900; `write_payload` 3,236 (owner mode) / 3,245 (other modes, V8); `consume` ~3,800; `approve` 3,263; `revoke` ~1,660; `resize` 4,600–6,300; `orphan_close` 2,648; `create` 8,300–23,300 depending on the object bump search. The event adds about 700 CU per instruction. The cost does not depend on the issuer. Issuers that rely on `orphan_close` SHOULD NOT migrate to loader-v4 (§4.4).
- **Release process.**
  1. Preview builds run on X1 testnet as one upgradeable program.
  2. Before production, compare active feature gates of testnet and mainnet.
  3. Production: deploy the candidate on mainnet **with** an upgrade authority, under a new program id; verify that the on-chain hash equals the verifiable build; run the full on-chain suite against that program id.
  4. Only then remove the upgrade authority (`set-upgrade-authority --final`), and verify again the hash, the program id and `Authority: none`. Publish the program id, hash, source tag, build image and both transaction signatures.
- **Multiple program ids.** Issuers SHOULD be able to accept more than one Mass Asset program id, each with its own format number, so that their assets stay redeemable after a newer program is adopted.

---

## Appendix A — Rationale (informative)

**A.1 Hard close.** Closing by zero lamports alone lets anyone re-fund the address in the same transaction and keep a ghost account owned by Mass Asset alive. Zeroing, resizing to 0 and assigning to System leaves nothing to revive.

**A.2 ProgramData owner.** A predicate such as "ProgramData has zero lamports" can be griefed: anyone can send the 0-byte rent minimum to a dead ProgramData address and turn it into a System-owned shell. A live program's ProgramData is always owned by the loader. On X1 mainnet (format 1) we verified the tested loader-v3 paths: the griefing shell does not block `orphan_close`, and 9 of 9 raw loader-v3 instructions on a closed program id were refused (in simulation, experiment X-2). The predicate's safety therefore rests on the current loader-v3 behaviour (§10); any change to supported loaders needs a new assessment.

**A.3 Stored authority bump.** The canonical search runs once at `create`; later checks cost one `create_program_address` for every issuer.

**A.4 Pairwise-distinct roles in `create` and `resize`.** A signer passed into the System CPI could otherwise be debited (payer = authority).

**A.5 Delegate semantics.** They follow SPL Token `approve` / `revoke`: one delegate, replaced by a new `approve`, cleared by transfer. The delegate is not cleared by `write_payload` or `resize`, because a sale itself settles rewards (and writes the payload) before the delegate transfers.

**A.6 Shared authority seed.** One issuer authority for both formats keeps issuers simple and lets one check (C7, T5, D6) exclude it as owner or delegate. The protection rests on E1. If an issuer ever works with both formats, sharing the authority must be assessed for that issuer.

## Appendix B — Display convention (informative)

To let marketplaces and explorers show a name and an image, an issuer MAY publish, in its documentation or a configuration account, a URI template such as `https://example.org/assets/{object}.json`, where `{object}` is the asset address in base58. The JSON follows the common NFT metadata shape (`name`, `description`, `image`, `attributes`). The core standard does not read or enforce it.

## Appendix C — Review decisions

| Item | Decision |
|---|---|
| G-MA2-01 | Delegate rights stated exactly (§2.2, §4.5); signature semantics (§2) |
| G-MA2-02 | E7; listing identity and closing (§8.2) |
| G-MA2-03 | R7 limited to accrued rewards with remainder kept; sale steps and remainder rule (§8.2) |
| G-MA2-04 | Strict consumer rules and full encoding (§7) |
| G-MA2-05 | Payer semantics, zero shortfall, System errors (§4.7) |
| G-MA2-06 | This document is self-contained (§0) |
| G-MA2-07 | Candidate tested before `--final` (§10) |
| G-MA2-08 | Sale steps with listing authenticity, buyer authorisation, re-check of owner and delegate, payment binding (§8.2) |
| G-MA2-09 | New listing = new id and PDA; cancel semantics (§8.2) |
| G-MA2-10 | R7 recipient fixed by issuer rule (MUST) |
| G-MA2-11 | I1 narrowed to assets created by `create` |
| G-MA2-15 | R4: a part of the position's value that cannot be paid at redemption may be recorded as a standalone claim of the current owner in issuer state (integration text only; no binary or ABI change) |
| Q1 | Shared authority seed (A.6) |
| Q2 | No executable check for delegates |
| Q3 | `resize` grows only |
| Q4 | Delegate not cleared by payload writes (A.5) |
| Q5 | Fixed binary segments with reference encodings (§7) |
