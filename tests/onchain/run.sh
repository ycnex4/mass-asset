#!/usr/bin/env bash
# Mass Asset v1 (format 2) — on-chain conformance suite (spec: docs/spec/v1-format2-draft.md).
#
# 1. Host unit tests, then SBF builds of Mass Asset and the disposable test issuer.
# 2. Deploys Mass Asset + test issuer A + test issuer B under FRESH program ids
#    (issuer B has a different authority bump than issuer A).
# 3. Phase "live" (issuer A): positive checks P1–P9, P12–P24 (delegate, rollback, resize, PDA payer),
#    negative checks N1–N19, N21–N57 (simulated), event checks E1–E13.
#    With MASS_PROGRAM_ID, the on-chain bytecode is compared with the local build first.
# 4. Phase "issuer-b": Mass Asset's own CU for authority-gated instructions must be
#    identical across issuers (U1–U4).
# 5. Closes issuer A, phase "orphan": orphan_close checks P10–P11, N20.
# 6. Closes issuer B and the Mass Asset deployment, so their rent comes back.
#
# Release bindings (checked by scripts/finalize.sh and scripts/deploy-candidate.sh):
#   "Genesis: …"            the network the run was on;
#   "Deployment before: …"  ProgramData, last deployment slot and authority of an existing Mass Asset
#                           program, read before the bytecode check; re-read after the tests, together
#                           with the bytecode: "Deployment: UNCHANGED" or the run fails;
#   "Cleanup: OK"           every program the suite deployed was closed (otherwise the run fails).
#
# Environment:
#   WALLET   keypair that pays for everything (default: ~/.config/solana/id.json)
#   X1_RPC   RPC endpoint (default: https://rpc.testnet.x1.xyz — format 2 is developed on testnet)
#   X1_NETWORK  testnet (default) | mainnet | any: the RPC must serve the network whose genesis hash is
#            pinned in release/networks.env; checked before anything is signed ("any": local/dev only)
#   MASS_SO  optional: test this prebuilt Mass Asset binary (e.g. from scripts/verifiable-build.sh)
#            instead of building one with cargo build-sbf. Its sha256 is printed in the log.
#   MASS_PROGRAM_ID  optional: test an ALREADY DEPLOYED Mass Asset program (e.g. the official
#            immutable one). Mass Asset is then neither built, deployed nor closed; only the
#            disposable test issuers are deployed and closed.
#
# Net cost ≈ fees + 3 program-account rents (~0.0034 XNT, kept by the loader)
#          + one 0-byte shell (~0.0009 XNT) intentionally left at the dead issuer ProgramData.
#          Deploy rent (~0.6 XNT) is needed temporarily and returned at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
HERE="$ROOT/tests/onchain"
MASS_DIR="$ROOT/programs/mass-asset-v1"
ISSUER_DIR="$HERE/test-issuer"
RPC="${X1_RPC:-https://rpc.testnet.x1.xyz}"
X1_NETWORK="${X1_NETWORK:-testnet}"
WALLET="${WALLET:-$HOME/.config/solana/id.json}"
MASS_SO_PREBUILT="${MASS_SO:-}"
MASS_SO="${MASS_SO:-$MASS_DIR/target/deploy/mass_asset_v1.so}"
# Fresh, throwaway program keypairs live here (not in target/, which a Docker build may own as root).
KEYS_DIR="$HERE/.keys"
MASS_KP="$KEYS_DIR/mass_asset_v1-keypair.json"
ISSUER_SO="$ISSUER_DIR/target/deploy/mass_asset_test_issuer.so"
ISSUER_KP="$KEYS_DIR/mass_asset_test_issuer-keypair.json"
ISSUER_B_KP="$KEYS_DIR/mass_asset_test_issuer_b-keypair.json"
STATE="$HERE/onchain.state.json"
LOG="$HERE/onchain.log"

cd "$ROOT"
exec > >(tee "$LOG") 2>&1

printf '\n=== MASS ASSET v1 (format 2) — ON-CHAIN CONFORMANCE SUITE ===\n'
printf 'Run: %s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf 'Repo:   %s\nCommit: %s\nRPC:    %s\nLog:    %s\n' "$ROOT" "$COMMIT" "$RPC" "$LOG"

[[ -f "$WALLET" ]] || { echo "ERROR: wallet keypair not found at $WALLET (set WALLET=...)" >&2; exit 1; }
[[ -d "$HERE/node_modules/@solana/web3.js" ]] || { echo "ERROR: run 'npm install' in tests/onchain first" >&2; exit 1; }
export PROBE_WALLET="$WALLET" X1_RPC="$RPC"
GENESIS="$(solana --url "$RPC" genesis-hash 2>/dev/null || true)"
[[ -n "$GENESIS" ]] || { echo "ERROR: cannot read the genesis hash from $RPC" >&2; exit 1; }
echo "Genesis: $GENESIS"
case "$X1_NETWORK" in
  mainnet|testnet)
    # shellcheck disable=SC1091
    source "$ROOT/release/networks.env"
    if [[ "$X1_NETWORK" == mainnet ]]; then EXPECTED="${MAINNET_GENESIS:-}"; else EXPECTED="${TESTNET_GENESIS:-}"; fi
    [[ -n "$EXPECTED" && "$GENESIS" == "$EXPECTED" ]] \
      || { echo "ERROR: $RPC is not X1 $X1_NETWORK (genesis $GENESIS, pinned '${EXPECTED}'); nothing signed" >&2; exit 1; }
    echo "Network: X1 $X1_NETWORK (pinned genesis)";;
  any) echo "Network: unpinned (X1_NETWORK=any; not valid as release evidence)";;
  *) echo "ERROR: X1_NETWORK must be testnet, mainnet or any" >&2; exit 1;;
esac
WALLET_PUBKEY="$(solana-keygen pubkey "$WALLET")"
balance() { solana --url "$RPC" balance "$WALLET_PUBKEY" --lamports | awk '{print $1}'; }
rent_for_so() { solana --url "$RPC" rent "$(( $(stat -c%s "$1") + 45 ))" --lamports | awk '/Rent-exempt minimum/{print $3}'; }
# shellcheck source=../../scripts/common.sh
source "$ROOT/scripts/common.sh"
close_program() {  # best effort, for early-exit paths
  solana --url "$RPC" --keypair "$WALLET" program close "$1" \
    --authority "$WALLET" --recipient "$WALLET_PUBKEY" --bypass-warning || true
}
CLEANUP_FAILED=""
close_tracked() {  # close_tracked <label> <program id>: the close must succeed and, at commitment
                  # finalized, its ProgramData account must be confirmed absent (an RPC error is not absence)
  local pd st=error
  pd="$(state_programdata "$(deployment_state "$RPC" "$2")")"
  if [[ "$pd" != "?" ]] && solana --url "$RPC" --keypair "$WALLET" program close "$2" \
       --authority "$WALLET" --recipient "$WALLET_PUBKEY" --bypass-warning; then
    for i in $(seq 1 20); do st="$(account_state "$RPC" "$pd")"; [[ "$st" == absent ]] && break; sleep 3; done
  fi
  if [[ "$st" == absent ]]; then
    echo "Cleanup: $1 $2 closed (ProgramData $pd absent at finalized)"
  else
    echo "Cleanup: $1 $2 NOT CONFIRMED CLOSED (ProgramData ${pd}: $st) — check, then close manually: solana program close $2 --bypass-warning"
    CLEANUP_FAILED+=" $1"
  fi
}

echo '[0/8] Host unit tests (Mass Asset)...'
(cd "$MASS_DIR" && cargo test --quiet)
EXISTING_MASS_ID="${MASS_PROGRAM_ID:-}"
BYTECODE_OK=0
if [[ -n "$EXISTING_MASS_ID" ]]; then
  echo "[1/8] Testing the deployed Mass Asset program $EXISTING_MASS_ID (no build/deploy/close)"
  solana --url "$RPC" program show "$EXISTING_MASS_ID"
  # Bind this run to a deployment and a binary (G-MA2-12): one finalized snapshot of the deployment
  # state and the bytecode, compared with the local build. Retries cover a node that has not yet
  # seen a fresh upgrade.
  BYTECODE_OK=0; STATE_BEFORE=""; ONCHAIN_HASH=""
  if command -v solana-verify >/dev/null && [[ -f "$MASS_SO" ]]; then
    LOCAL_HASH="$(solana-verify get-executable-hash "$MASS_SO")"
    snapshot "$RPC" "$EXISTING_MASS_ID" "$LOCAL_HASH"
    STATE_BEFORE="$SNAP_STATE"; ONCHAIN_HASH="$SNAP_HASH"
    echo "Deployment before: ${STATE_BEFORE:-unavailable}"
    printf 'Bytecode: on-chain %s (finalized snapshot)\n          local    %s (%s, sha256 %s)\n' \
      "${ONCHAIN_HASH:-unavailable}" "$LOCAL_HASH" "$MASS_SO" "$(sha256sum "$MASS_SO" | awk '{print $1}')"
    [[ -n "$STATE_BEFORE" && "$ONCHAIN_HASH" == "$LOCAL_HASH" ]] && BYTECODE_OK=1
    (( BYTECODE_OK )) && echo "Bytecode: MATCH" || echo "Bytecode: MISMATCH"
  else
    echo "Bytecode: not compared (needs solana-verify and a local binary at $MASS_SO)"
  fi
elif [[ -n "$MASS_SO_PREBUILT" ]]; then
  echo "[1/8] Using prebuilt Mass Asset binary: $MASS_SO"
  [[ -f "$MASS_SO" ]] || { echo "ERROR: MASS_SO not found: $MASS_SO" >&2; exit 1; }
else
  echo '[1/8] Building Mass Asset v1...'
  (cd "$MASS_DIR" && cargo build-sbf)
fi
echo '[2/8] Building test issuer...'
(cd "$ISSUER_DIR" && cargo build-sbf)
[[ -n "$EXISTING_MASS_ID" ]] || printf 'Mass Asset .so: %s bytes, sha256 %s\n' "$(stat -c%s "$MASS_SO")" "$(sha256sum "$MASS_SO" | awk '{print $1}')"

echo '[3/8] Fresh program keypairs...'
mkdir -p "$KEYS_DIR"
if [[ -n "$EXISTING_MASS_ID" ]]; then
  MASS_ID="$EXISTING_MASS_ID"
else
  solana-keygen new --no-bip39-passphrase --silent --force -o "$MASS_KP" >/dev/null
  MASS_ID="$(solana-keygen pubkey "$MASS_KP")"
fi
solana-keygen new --no-bip39-passphrase --silent --force -o "$ISSUER_KP" >/dev/null
ISSUER_ID="$(solana-keygen pubkey "$ISSUER_KP")"
# Issuer B: a fresh keypair whose authority bump differs from issuer A's.
(cd "$HERE" && node -e '
const fs = require("fs");
const { Keypair, PublicKey } = require("@solana/web3.js");
const seed = [Buffer.from("mass-asset-authority")];
const bumpOf = (pk) => PublicKey.findProgramAddressSync(seed, pk)[1];
const a = bumpOf(new PublicKey(process.argv[1]));
let kp, b;
do { kp = Keypair.generate(); b = bumpOf(kp.publicKey); } while (b === a);
fs.writeFileSync(process.argv[2], JSON.stringify(Array.from(kp.secretKey)));
console.log(`authority bump: issuer A=${a} issuer B=${b}`);
' "$ISSUER_ID" "$ISSUER_B_KP")
ISSUER_B_ID="$(solana-keygen pubkey "$ISSUER_B_KP")"
printf 'Mass Asset v1:  %s\nTest issuer A:  %s\nTest issuer B:  %s\n' "$MASS_ID" "$ISSUER_ID" "$ISSUER_B_ID"

MASS_RENT=0; [[ -n "$EXISTING_MASS_ID" ]] || MASS_RENT="$(rent_for_so "$MASS_SO")"
NEED=$(( MASS_RENT + 2 * $(rent_for_so "$ISSUER_SO") + 60000000 ))
BAL_START="$(balance)"
printf 'Wallet: %s\nBalance: %s lamports, needed (deploy rent + 0.06 XNT margin): %s lamports\n' "$WALLET_PUBKEY" "$BAL_START" "$NEED"
if (( BAL_START < NEED )); then
  echo "ERROR: top up the wallet by at least $(( NEED - BAL_START )) lamports. Deploy rent is returned at the end." >&2
  exit 1
fi

echo '[ENV] loader-v4 related feature gates on this cluster:'
solana --url "$RPC" feature status 2>/dev/null | grep -i -E 'loader|v4|migrat' || echo '  (none listed / feature status unavailable)'

echo '[4/8] Deploying Mass Asset, issuer A, issuer B...'
[[ -n "$EXISTING_MASS_ID" ]] || solana --url "$RPC" --keypair "$WALLET" program deploy "$MASS_SO" --program-id "$MASS_KP" --upgrade-authority "$WALLET"
if ! solana --url "$RPC" --keypair "$WALLET" program deploy "$ISSUER_SO" --program-id "$ISSUER_KP" --upgrade-authority "$WALLET"; then
  echo "ERROR: issuer A deploy failed." >&2
  [[ -n "$EXISTING_MASS_ID" ]] || close_program "$MASS_ID"; exit 1
fi
if ! solana --url "$RPC" --keypair "$WALLET" program deploy "$ISSUER_SO" --program-id "$ISSUER_B_KP" --upgrade-authority "$WALLET"; then
  echo "ERROR: issuer B deploy failed; closing the other programs to return their rent." >&2
  close_program "$ISSUER_ID"; [[ -n "$EXISTING_MASS_ID" ]] || close_program "$MASS_ID"; exit 1
fi

FAILED_PHASES=""
[[ -z "$EXISTING_MASS_ID" || "$BYTECODE_OK" == 1 ]] || FAILED_PHASES+=" bytecode"
echo '[5/8] Phase LIVE...'
node "$HERE/onchain-suite.mjs" live "$MASS_ID" "$ISSUER_ID" "$STATE" || { echo "ERROR: live phase failed"; FAILED_PHASES+=" live"; }

echo '[6/8] Phase ISSUER-B (constant authority cost)...'
if [[ -f "$STATE" ]]; then
  node "$HERE/onchain-suite.mjs" issuer-b "$MASS_ID" "$ISSUER_B_ID" "$STATE" || { echo "ERROR: issuer-b phase failed"; FAILED_PHASES+=" issuer-b"; }
else
  FAILED_PHASES+=" issuer-b(skipped)"
fi
close_tracked issuer-b "$ISSUER_B_ID"

echo '[7/8] Closing test issuer A (namespace disappears), phase ORPHAN...'
close_tracked issuer-a "$ISSUER_ID"
if [[ -f "$STATE" ]]; then
  node "$HERE/onchain-suite.mjs" orphan "$MASS_ID" "$ISSUER_ID" "$STATE" || { echo "ERROR: orphan phase failed"; FAILED_PHASES+=" orphan"; }
else
  echo "ERROR: no state file from live phase; skipping orphan phase."; FAILED_PHASES+=" orphan(skipped)"
fi

if [[ -n "$EXISTING_MASS_ID" ]]; then
  echo '[8/8] Mass Asset was an existing deployment; not closing it. Re-checking it...'
  snapshot "$RPC" "$EXISTING_MASS_ID" "${ONCHAIN_HASH:-}"
  STATE_AFTER="$SNAP_STATE"; HASH_AFTER="$SNAP_HASH"
  echo "Deployment after:  $STATE_AFTER"
  echo "Bytecode after:    $HASH_AFTER"
  if [[ -n "$STATE_BEFORE" && "$STATE_AFTER" == "$STATE_BEFORE" && -n "$HASH_AFTER" && "$HASH_AFTER" == "$ONCHAIN_HASH" ]]; then
    echo "Deployment: UNCHANGED"
  else
    echo "Deployment: CHANGED during the run"; FAILED_PHASES+=" deployment-changed"
  fi
else
  echo '[8/8] Closing the Mass Asset deployment (returns its rent)...'
  close_tracked mass-asset "$MASS_ID"
fi
if [[ -z "$CLEANUP_FAILED" ]]; then echo "Cleanup: OK"; else echo "Cleanup: FAILED:$CLEANUP_FAILED"; FAILED_PHASES+=" cleanup"; fi
rm -f "$STATE"

BAL_END="$(balance)"
printf '\nBalance start: %s\nBalance end:   %s\nNet cost:      %s lamports\n' "$BAL_START" "$BAL_END" "$(( BAL_START - BAL_END ))"
if [[ -n "$FAILED_PHASES" ]]; then
  printf '\n=== ON-CHAIN SUITE FAILED:%s ===\nSaved full log: %s\n' "$FAILED_PHASES" "$LOG"
  exit 1
fi
printf '\n=== ON-CHAIN SUITE PASSED ===\nSaved full log: %s\n' "$LOG"
