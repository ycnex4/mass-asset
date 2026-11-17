# Mass Asset v1 (format 2) — production release on X1 mainnet

The program is released once, under a new vanity id `MAss…`, and ends up **immutable**. The process is
**candidate first**: the exact verifiable binary is deployed under the final id *with* an upgrade
authority, tested on mainnet by the Mass Asset suite and together with FLUX (FLUX concept v0.14, §8.3),
and only then made final. If anything fails before finalization, the candidate is fixed and upgraded in
place; nothing is lost but fees.

Keys and seed phrases stay on the operator's machine. Every signing command below is run by the operator.
Lines marked ⚠️ touch secret key files: never paste their contents, and never print a keypair file.

What the scripts bind together, and refuse without:

| Binding | Where it is checked |
|---|---|
| network = X1 mainnet / testnet by **genesis hash** (`release/networks.env`), not by RPC URL, before anything is signed | every release script, `preview-deploy.sh` (and the pinned preview id), the suite runner (`X1_NETWORK`) |
| on-chain state read at commitment **finalized**: Program + ProgramData from **one** `getMultipleAccounts` response, the executable hash from the bytecode in that same response (`tests/onchain/snapshot.mjs`) | all release scripts and the suite runner |
| every transaction the suite (and the FLUX check) relied on reached **finalized** with the outcome observed at confirmed | suite phases (`Finalized: all N transactions of phase …`) |
| "absent" only on an explicit `AccountNotFound`; an RPC error stops the script | deploy decisions, cleanup checks |
| binary = verifiable build from a **fresh** clean checkout of a **published** commit of the pinned public repository, in the image pinned **by digest** | `verifiable-build.sh`, `load_build_record` (all release scripts) |
| testnet rehearsal of **this** binary passed | `deploy-candidate.sh`, before deploying |
| program id = the recorded candidate (`build/candidate.txt`) | `deploy-candidate.sh` (re-runs), `finalize.sh` |
| suite run and FLUX check = **one** run each (every binding line exactly once), in **pinned** network mode, against **this deployment** (ProgramData, last deployment slot, authority), unchanged during the run, test programs confirmed closed | `finalize.sh`; `deploy-candidate.sh` for the testnet log |
| the files checked are the files hashed: logs are copied first, the copies are checked, hashed and recorded before signing (the attempt's `finalize-intent.txt`) | `finalize.sh`, `deploy-candidate.sh` |
| deployment unchanged between the checks and the signature | `finalize.sh`, snapshot again after `FINALIZE` is typed |
| one release operation at a time (lock); one directory per attempt, never overwritten; no candidate deploy/upgrade while an attempt with a signed transaction is open or after finalization | `finalize.sh`, `deploy-candidate.sh` |
| the finalization transaction's own signature is recorded **before** sending; its result is read from the network (finalized, `err` null, signature and blockhash as recorded, exactly `SetAuthority(None)` on this ProgramData by the wallet); while an attempt is open, re-runs only verify; a new signature is allowed only after a finalized snapshot proves nothing changed | `finalize.sh` + `tests/onchain/finalize-tx.mjs` |

Records (`candidate.txt`, `deployment.txt`) are written only after every check passed.

## 0. Preconditions

**Public repository (clean start).** Format 2 is published in a fresh public repository; the format-1
repository is kept out of the way, not deleted (its program `MAssPQX…` stays on chain, and its source
stays inspectable):

1. Add one line to the README of `ycnex4/mass-asset` ("Superseded format 1, not maintained. Current
   version: https://github.com/ycnex4/mass-asset"), rename the repository to `ycnex4/mass-asset-format1`,
   then archive it. The pointer goes in first: once the old name is reused by the new repository, GitHub
   no longer redirects old URLs.
2. Create a new public `ycnex4/mass-asset` with a clean history: the reviewed format-2 tree (this
   directory as the repository root, the spec under `docs/spec/`), one initial commit. No tags yet.

**Pinned parameters.** `release/networks.env` holds the genesis hashes of X1 mainnet
(`4SvBP3om…`) and testnet (`C7ucgdDE…`), taken from the official endpoints on 2026-11-16, and
`PREVIEW_PROGRAM_ID`, `SOURCE_REPO` and `BUILD_IMAGE`. To re-check the genesis hashes (no secrets):

```bash
solana genesis-hash --url https://rpc.mainnet.x1.xyz
solana genesis-hash --url https://rpc.testnet.x1.xyz
```

**Build image by digest.** Fill `BUILD_IMAGE` (commit and review the change):

```bash
docker pull solanafoundation/solana-verifiable-build:<version>
docker inspect --format '{{index .RepoDigests 0}}' solanafoundation/solana-verifiable-build:<version>
```

The image must ship a toolchain new enough for the locked dependencies (cargo ≥ 1.85).

**Release wallet.** A dedicated mainnet wallet, used for nothing else from step 4 until step 7 is done
(no other terminal, script or session signs with it meanwhile), with about **2 XNT**: program rent
(≈ 0.4 XNT for a ~54 KB binary, locked forever once final), fees, ≈ 0.6 XNT that the suite needs
temporarily and returns, and the FLUX check in step 6.

**Tools.** Docker (running), `solana` CLI, `solana-verify` (`cargo install solana-verify`), Node for the
suite. Record their versions in the release notes.

## 1. Program id (vanity `MAss…`)

⚠️ The command writes a **secret** keypair file `MAss….json` into the current directory. It prints only
the file name and the public key. Run it in a dedicated, private directory:

```bash
mkdir -p ~/mass-asset-keys/v1 && chmod 700 ~/mass-asset-keys/v1 && cd ~/mass-asset-keys/v1
solana-keygen grind --starts-with MAss:1
chmod 600 MAss*.json
solana-keygen pubkey MAss*.json      # public key only — safe to share
```

The prefix is case-sensitive (4 characters: a few minutes). Make an **offline backup** of the keypair
file before any deployment; losing it before step 4 means grinding a new id, after step 4 it is no
longer needed for the program (the upgrade authority is the wallet).

## 2. Verifiable build from a clean checkout

```bash
git clone https://github.com/ycnex4/mass-asset ~/mass-asset-release-rc1 && cd ~/mass-asset-release-rc1
git checkout <release commit>    # pushed: the tip of main or of a tag such as v1.0.0-rc1
cd tests/onchain && npm ci && cd ../..
./scripts/verifiable-build.sh
```

The script refuses unless: no change in the tree (tracked or untracked; a failing `git status` is a
refusal too), no `target/` from an earlier build (a fresh clone per build), origin = `SOURCE_REPO`, the
commit is a branch or tag tip there (`git ls-remote`), and `BUILD_IMAGE` is pinned by digest. It records
`release_build: yes`, repo, commit, image, executable hash in `build/mass_asset_v1.sha256`. The release
scripts re-check all of it and refuse a binary whose hash differs from the record: do **not** run
`cargo build-sbf` afterwards.

## 3. Testnet rehearsal of the exact binary

The testnet preview ran a `cargo build-sbf` binary; the verifiable binary has a different hash and must
pass the suite itself before mainnet:

```bash
MASS_SO=programs/mass-asset-v1/target/deploy/mass_asset_v1.so ./scripts/preview-deploy.sh
X1_NETWORK=testnet X1_RPC=https://rpc.testnet.x1.xyz MASS_PROGRAM_ID=CjbH76UhFC1BWCZEdnGGPK3XmV7n5xjKgzPDQ4FStD6R \
  MASS_SO=programs/mass-asset-v1/target/deploy/mass_asset_v1.so tests/onchain/run.sh
cp tests/onchain/onchain.log evidence/testnet-v1-rc-pass.log
```

`preview-deploy.sh` refuses another network or another program id than the pinned preview, before
signing. Required in the log: testnet `Genesis:`, `Bytecode: MATCH` with the recorded hash, `Deployment: UNCHANGED`,
`Cleanup: OK`, `=== ON-CHAIN SUITE PASSED ===`. Step 4 checks all of them.

## 4. Mainnet candidate

```bash
PROGRAM_KEYPAIR=~/mass-asset-keys/v1/MAss….json ./scripts/deploy-candidate.sh
```

Refuses unless the RPC is mainnet by genesis hash, the binary is the clean verifiable build of the
public repository, the testnet log of step 3 is a complete PASSED run of this binary, and the id has the
`MAss` prefix (and equals the recorded candidate on re-runs). Deploys with the wallet as upgrade
authority (or upgrades the existing candidate of the same authority), checks the deployment, authority
and on-chain executable hash, and only then writes `build/candidate.txt` (ProgramData, slot, hash,
commit, sha256 of the testnet log).

The candidate is upgradeable: it is **not announced** and no issuer uses it until step 7.

## 5. Full suite against the candidate on mainnet

```bash
X1_NETWORK=mainnet X1_RPC=https://rpc.mainnet.x1.xyz MASS_PROGRAM_ID=MAss… \
  MASS_SO=programs/mass-asset-v1/target/deploy/mass_asset_v1.so tests/onchain/run.sh
```

The suite refuses a network other than pinned mainnet before signing, records a run id, the genesis
hash and a finalized snapshot of the deployment, compares the bytecode, runs every check, closes its two
disposable test issuers (each confirmed by its ProgramData being absent at finalized: `Cleanup: OK`),
then takes the snapshot again (`Deployment: UNCHANGED`). Any failure fails the run. Mass Asset itself is
not closed.

## 6. FLUX check against the candidate (FLUX v0.14, §8.3)

A **test** FLUX release (decided 16.11.2026) is checked on mainnet against the candidate: its own test
mint, its own XDEX pool with minimum amounts, a test FLUX program id. The test build shortens only the
calendar (epochs, windows, tranche days); it uses the real XDEX `open_pool` path (no `dev_open_pool`)
and a fixed authority bump for the test FLUX id, with `MASS_ASSET_PROGRAM_ID = MAss…`. Covered: pool
creation and first deposit, the full position cycle with the minimum amount (both FLUX sources),
redemption through the candidate, execution limits. Before the test program is closed, every position
is redeemed and the remainders are accounted for; the burned initial liquidity stays in the test pool.
Separately, the FLUX release binary is checked: production Mass Asset id, bump of the final FLUX id,
production intervals, no `dev_open_pool`. The tooling lives in `flux1-contracts`. Its log, saved as
`evidence/flux-mainnet-check.log`, must contain these exact lines (the contract `finalize.sh` checks):

```
Run: <unique run id>
Genesis: <mainnet genesis hash>
Network: X1 mainnet (pinned genesis)
Mass Asset program: <MAss… id>
Mass Asset deployment before: programdata=<…> slot=<…> authority=<wallet>
Mass Asset bytecode: <executable hash>
Finalized: all <N> transactions
Mass Asset deployment: UNCHANGED
=== FLUX MAINNET CHECK PASSED ===          (among the last 3 lines)
```

Each line exactly once (one run per log). The deployment and bytecode lines come from the same kind of
finalized single-response snapshot as the Mass Asset suite.

**Any fix in steps 5–6** means: new commit in the public repository → step 2 → 3 → 4 (upgrade; if the
binary is larger than the program data account, first
`solana --url https://rpc.mainnet.x1.xyz program extend MAss… <additional bytes>`) → 5 → 6. The upgrade
changes the deployment slot, so every earlier log stops matching.

## 7. Finalize

```bash
./scripts/finalize.sh
```

Takes the program id from `build/candidate.txt`. The whole run holds an exclusive lock
(`build/.finalize.lock`), and each attempt has its own directory `build/finalize/attempt-…/` that is
never deleted or overwritten.

Before signing it refuses unless, all at once: mainnet by genesis hash; release build matching the
record; a finalized single-response snapshot of the live deployment = the recorded one, with authority =
wallet and on-chain hash = build hash; the **frozen copies** of the suite log (step 5) and the FLUX log
(step 6), copied first into the attempt and then checked and hashed, are single pinned-mainnet PASSED
runs bound to this deployment. The intent (log hashes, deployment, candidate record hash) is written to
the attempt before signing. After `FINALIZE` is typed the snapshot is taken again; any change aborts.

`tests/onchain/finalize-tx.mjs` then builds `SetAuthority(None)` for the ProgramData, signs it, records
signature, blockhash, last valid block height and the intent hash **before** sending, sends once, and
reads the result from the network only (finalized; response signature and blockhash as recorded; exactly
that instruction and those accounts). From then on the attempt is **open**, and every run of
`finalize.sh` only verifies it — it never signs again — after checking that candidate record, intent and
transaction record belong together. An open attempt is closed only by evidence:

- **verified** — transaction finalized with `meta` present and `err` null, and the post-checks pass on a
  snapshot whose context is at or after the transaction slot (same ProgramData and slot, authority none,
  hash, frozen logs unchanged). The attempt's `deployment.txt` is published to `build/deployment.txt` by
  an atomic rename **before** the attempt is marked closed; if `build/deployment.txt` is missing later,
  the next run republishes it from the verified attempt without signing;
- **not executed** (expiry established by the slot and block height of one finalized block, authority
  unchanged in a context at or after that slot) or **executed with an error** (explicit `meta.err`) —
  and a full
  finalized snapshot (same ProgramData, slot, authority, bytecode) from a context at or after the slot
  where that outcome was established → a new attempt is allowed on the next run.

Only the output of the current run decides; a missing or invalid slot keeps the attempt open. Anything
else leaves the attempt open with `UNVERIFIED.txt`; run the script again later. **Irreversible.**

Residual window: between the last snapshot and the signature there are seconds; the dedicated release
wallet (step 0) is what keeps any other upgrade out of them.

## 8. Publish

1. Copy `build/mass_asset_v1.sha256`, `build/candidate.txt`, `build/candidate-testnet-suite.log`,
   `build/deployment.txt` and the whole `build/finalize/` directory (every attempt) into `evidence/`;
   commit to the public repository.
2. Spec: status DRAFT 5 → **v1.0**, program id in §0.1 and §0.2.
3. Tag `v1.0.0` and a release: program id, `deployment.txt`, the reproduction command
   (`solana-verify verify-from-repo --program-id MAss… https://github.com/ycnex4/mass-asset
   --commit-hash <commit> --library-name mass_asset_v1 --mount-path programs/mass-asset-v1`), and a note
   that format 1 assets are not compatible.
4. FLUX: the network build keeps `MASS_ASSET_PROGRAM_ID = MAss…` from step 6.
