# Mass Asset

An on-chain asset standard for X1 (SVM) — **format 2** (Mass Asset v1), released as v1.0.

## Deployment (v1.0)

| | |
|---|---|
| Program id (X1 mainnet) | **`MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp`** |
| Status | **immutable** — upgrade authority removed (tx `5pXc2hBW1f7TEhgN8bJkqQMyapwGkBrCWTDymkeX5yJm2m7gRRPgcAx2kQiUhNoqNtVpYtDcu4ojzvcHBfupXAYe`, slot 93867662) |
| ProgramData | `337gFTimc9Lvxa8wR3Pbh4R4ZRhEAWu6qpnFBAJDM7na`, deployed in slot 93853701 |
| Executable hash | `88ff9a9c70bf6bef3c418eb81f75d9d8b2e927eaee1ab4c7485362fd09c9216c` |
| Source | commit `d209d04` (tag `v1.0.0-rc1`), built with `solana-verifiable-build@sha256:0b4e3716…bdd68` |
| Evidence | [`evidence/`](evidence/) — build record, candidate, testnet and mainnet suite logs, FLUX check, finalization |

Reproduce the build and compare it with the deployed program:

```bash
solana-verify verify-from-repo -u https://rpc.mainnet.x1.xyz --program-id MAssXtCndQhigtQDDpwkwrUiSQbjT1jkkrXoXzZEtUp \
  https://github.com/ycnex4/mass-asset --commit-hash d209d04fbc80c172ad8413c3cbcbf904949e52e8 \
  --library-name mass_asset_v1 --mount-path programs/mass-asset-v1 \
  --base-image solanafoundation/solana-verifiable-build@sha256:0b4e3716fad9ca4b4aac3e3f977f43aad93a18c22296c0c0f44fc22e644bdd68
```

**Format 1 is not compatible.** Format 1 (`MAssPQXuBXvvf196oXKFZ1GiC9kTsJJ8podQV3m72Wv`, immutable, superseded)
is a different program with a different account layout; its assets are not format 2 assets. Its code lives
in the archived repository [`ycnex4/mass-asset-format1`](https://github.com/ycnex4/mass-asset-format1).
An integrator identifies a format by the pair (account owner program id, `version`).

## What it is

- **One account per asset**, at a PDA of the Mass Asset program (`ma1-asset` seed), with a 104-byte header
  and an issuer-defined payload.
- **Issuer.** Each asset belongs to one issuer program, which acts through its authority PDA
  (`mass-asset-authority`): it creates the asset, writes and grows its payload (`resize`), and consumes it.
- **Transfer** follows the asset's mode: the owner, the issuer, or nobody (frozen). In owner mode the owner
  can approve one **delegate** that may transfer the asset once (`approve` / `revoke`).
- **Closing.** Consuming an asset closes its account and returns all of its rent to the owner;
  `orphan_close` covers an issuer program that was itself closed.
- **Events.** Every successful instruction emits one `sol_log_data` record (fixed segments, reference
  encodings in the specification).

The rules, layout, check order and error codes are in the specification:
[`docs/spec/v1-format2-draft.md`](docs/spec/v1-format2-draft.md) (v1.0).

## Repository

| Path | What |
|---|---|
| `programs/mass-asset-v1/` | the program, with host unit tests |
| `tests/onchain/` | on-chain conformance suite (`run.sh`) and the release snapshot / finalize tools |
| `scripts/verifiable-build.sh` | deterministic build in Docker (`solana-verify`); records the executable hash |
| `scripts/preview-deploy.sh` | deploy or upgrade the testnet preview |
| `scripts/deploy-candidate.sh`, `scripts/finalize.sh` | mainnet release, candidate first (see `RELEASE.md`) |
| `release/networks.env` | pinned genesis hashes of X1 mainnet and testnet, preview id, source repository, build image |
| `RELEASE.md` | the release procedure and its evidence requirements |
| `evidence/` | release evidence (filled in by the release) |

## Build and test

```bash
cd programs/mass-asset-v1 && cargo test && cargo build-sbf
cd ../../tests/onchain && npm install && ./run.sh   # against X1 testnet by default; see tests/onchain/README.md
```

The release binary is built with `scripts/verifiable-build.sh` from a fresh clone of a published commit,
so anyone can rebuild it and compare the executable hash with the deployed program.

## License

Apache-2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
