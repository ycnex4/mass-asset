#!/usr/bin/env bash
# Rehearsal of the finalization transaction on X1 TESTNET with a throwaway program (never the preview
# program, never Mass Asset): proves the success branch of finalize-tx.mjs (exit 0) and the read-only
# recovery path (verify of the same record, exit 0) on a real network, plus two refusals.
#
# What it does, signed by WALLET on testnet only:
#   1. deploys the disposable test issuer under a fresh throwaway program id (upgrade authority WALLET);
#   2. finalize-tx.mjs send  → SetAuthority(None): the throwaway program becomes immutable (its rent,
#      ≈ 0.2 testnet XNT, stays locked — testnet only);
#   3. finalize-tx.mjs verify of the same record (recovery path, no signing) → must be exit 0;
#   4. verify of the record with a wrong blockhash → must be exit 5 (unexpected transaction);
#   5. finalized snapshot: same ProgramData and slot, authority none.
#
# Environment: WALLET (default ~/.config/solana/id.json), X1_RPC (default TESTNET_RPC).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/scripts/common.sh"
load_networks "$ROOT"
RPC="${X1_RPC:-$TESTNET_RPC}"
WALLET="${WALLET:-$HOME/.config/solana/id.json}"
OUT="$HERE/finalize-rehearsal"
LOG="$OUT/rehearsal.log"
mkdir -p "$OUT" "$HERE/.keys"
exec > >(tee "$LOG") 2>&1

echo "=== FINALIZE-TX REHEARSAL (testnet, throwaway program) ==="
echo "Run: $(date -u +%Y%m%dT%H%M%SZ)-$$"
require_network "$RPC" "$TESTNET_GENESIS" "X1 testnet"
[[ -f "$WALLET" ]] || { echo "ERROR: wallet not found: $WALLET" >&2; exit 1; }
[[ -d "$HERE/node_modules/@solana/web3.js" ]] || { echo "ERROR: run 'npm ci' in tests/onchain" >&2; exit 1; }
WALLET_PUBKEY="$(solana-keygen pubkey "$WALLET")"

echo "[1/5] Build and deploy the test issuer under a throwaway id"
(cd "$HERE/test-issuer" && cargo build-sbf)
SO="$HERE/test-issuer/target/deploy/mass_asset_test_issuer.so"
KP="$HERE/.keys/finalize-rehearsal-program.json"
solana-keygen new --no-bip39-passphrase --silent --force -o "$KP" >/dev/null
ID="$(solana-keygen pubkey "$KP")"
echo "Throwaway program: $ID"
[[ "$ID" != "$PREVIEW_PROGRAM_ID" ]] || { echo "ERROR: refusing to touch the preview program" >&2; exit 1; }
solana --url "$RPC" --keypair "$WALLET" program deploy "$SO" --program-id "$KP" --upgrade-authority "$WALLET"
snapshot "$RPC" "$ID"
echo "Before: ${SNAP_STATE:-unavailable} hash=${SNAP_HASH:-?} context=${SNAP_CONTEXT:-?}"
[[ "$SNAP_STATE" == *" authority=$WALLET_PUBKEY" ]] || { echo "ERROR: unexpected state before" >&2; exit 1; }
BEFORE="$SNAP_STATE"; HASH="$SNAP_HASH"

ok=1
echo "[2/5] finalize-tx.mjs send"
REC="$OUT/finalize-tx-$(date -u +%Y%m%dT%H%M%SZ).json"
INTENT_SHA="$(printf 'rehearsal %s %s' "$ID" "$BEFORE" | sha256sum | cut -d' ' -f1)"
set +e
(cd "$HERE" && node finalize-tx.mjs send "$RPC" "$WALLET" "$ID" "$REC" "$INTENT_SHA"); RC=$?
echo "send exit $RC"; [[ $RC == 0 ]] || ok=0
echo "[3/5] finalize-tx.mjs verify of the same record (recovery path, no signing)"
(cd "$HERE" && node finalize-tx.mjs verify "$RPC" "$REC"); RC=$?
echo "verify exit $RC"; [[ $RC == 0 ]] || ok=0
echo "[4/5] verify with a wrong blockhash in the record (must be refused: exit 5)"
BAD="$OUT/bad-blockhash.json"
sed 's/"blockhash": *"[^"]*"/"blockhash": "11111111111111111111111111111111"/' "$REC" > "$BAD"
(cd "$HERE" && node finalize-tx.mjs verify "$RPC" "$BAD"); RC=$?
echo "verify (bad blockhash) exit $RC"; [[ $RC == 5 ]] || ok=0
set -e
echo "[5/5] finalized snapshot after"
snapshot "$RPC" "$ID" "$HASH"
echo "After:  ${SNAP_STATE:-unavailable} hash=${SNAP_HASH:-?} context=${SNAP_CONTEXT:-?}"
[[ "$SNAP_STATE" == "${BEFORE% authority=*} authority=none" && "$SNAP_HASH" == "$HASH" ]] || ok=0

if (( ok )); then echo; echo "=== FINALIZE-TX REHEARSAL PASSED ==="; else echo; echo "=== FINALIZE-TX REHEARSAL FAILED ==="; exit 1; fi
echo "Saved: $LOG"
