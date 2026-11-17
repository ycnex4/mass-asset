# Mass Asset v1.0.0 — format 2, immutable on X1 mainnet

**Program id:** `MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp` (X1 mainnet), **immutable** — the upgrade authority
was removed by `5pXc2hBW1f7TEhgN8bJkqQMyapwGkBrCWTDymkeX5yJm2m7gRRPgcAx2kQiUhNoqNtVpYtDcu4ojzvcHBfupXAYe`
(slot 93867662).

| | |
|---|---|
| ProgramData | `337gFTimc9Lvxa8wR3Pbh4R4ZRhEAWu6qpnFBAJDM7na`, deployed in slot 93853701 |
| Executable hash | `88ff9a9c70bf6bef3c418eb81f75d9d8b2e927eaee1ab4c7485362fd09c9216c` |
| Source commit | `d209d04fbc80c172ad8413c3cbcbf904949e52e8` (tag `v1.0.0-rc1`) |
| Build image | `solanafoundation/solana-verifiable-build@sha256:0b4e3716fad9ca4b4aac3e3f977f43aad93a18c22296c0c0f44fc22e644bdd68` |
| Specification | `docs/spec/v1-format2-draft.md` — v1.0 |
| Deployment record | `evidence/deployment.txt` |

## Verify

```bash
solana-verify verify-from-repo -u https://rpc.mainnet.x1.xyz --program-id MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp \
  https://github.com/ycnex4/mass-asset --commit-hash d209d04fbc80c172ad8413c3cbcbf904949e52e8 \
  --library-name mass_asset_v1 --mount-path programs/mass-asset-v1 \
  --base-image solanafoundation/solana-verifiable-build@sha256:0b4e3716fad9ca4b4aac3e3f977f43aad93a18c22296c0c0f44fc22e644bdd68
```

Run by the operator on 2026-11-17 after finalization: the repository build and the on-chain program both
give `88ff9a9c70bf6bef3c418eb81f75d9d8b2e927eaee1ab4c7485362fd09c9216c` — **Program hash matches**.

## What was checked before finalization

- conformance suite on X1 testnet against this exact bytecode, and on X1 mainnet against the candidate;
- a test FLUX release on X1 mainnet against the candidate (pool creation, the full position cycle from both
  sources, cleanup; 288 finalized transactions; the candidate unchanged throughout);
- the finalization transaction rehearsed on testnet; then signed, recorded before sending and verified on
  mainnet. All logs are in `evidence/`.

## Compatibility

**Format 1 assets are not compatible.** Format 1 (`MAssPQXuBXvvf196oXKFZ1GiC9kTsJJ8podQV3m72Wv`) is a different,
superseded program with a different account layout (`version` 1, 72-byte header, `mass-asset` seed); format 2
uses `version` 2, a 104-byte header and the `ma1-asset` seed. Identify a format by the pair (account owner
program id, `version`). Format 1 code: [`ycnex4/mass-asset-format1`](https://github.com/ycnex4/mass-asset-format1)
(archived).
