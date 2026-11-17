# Mass Asset

An on-chain asset standard for X1 (SVM) — **format 2** (Mass Asset v1).

> **Status: pre-release.** The specification is a published draft and the program runs as a preview on
> X1 testnet. It is **not yet deployed on mainnet**; the program id is published with the v1.0 release.
> Format 1 (`MAssPQXuBXvvf196oXKFZ1GiC9kTsJJ8podQV3m72Wv`, immutable, superseded) lives in the archived
> repository [`ycnex4/mass-asset-format1`](https://github.com/ycnex4/mass-asset-format1).

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
[`docs/spec/v1-format2-draft.md`](docs/spec/v1-format2-draft.md).

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
