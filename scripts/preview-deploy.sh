#!/usr/bin/env bash
# Mass Asset v1 (format 2) — PREVIEW deployment on X1 TESTNET (upgradeable).
#
# First run: deploys the program under the preview program id.
# Later runs: upgrades the same program in place (same id, same upgrade authority).
# The preview program is for tests only; it is closed when the preview phase ends.
#
# Environment:
#   PROGRAM_KEYPAIR  preview program keypair (default: ~/mass-asset-keys/preview/program.json)
#   WALLET           payer and upgrade authority (default: ~/.config/solana/id.json)
#   X1_RPC           testnet RPC (default: TESTNET_RPC); refused unless its genesis hash is the pinned
#                    testnet one and PROGRAM_KEYPAIR is the pinned PREVIEW_PROGRAM_ID
#   MASS_SO          optional prebuilt binary; otherwise built with cargo build-sbf
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/common.sh"
load_networks "$ROOT"
MASS_DIR="$ROOT/programs/mass-asset-v1"
RPC="${X1_RPC:-$TESTNET_RPC}"
WALLET="${WALLET:-$HOME/.config/solana/id.json}"
PROGRAM_KEYPAIR="${PROGRAM_KEYPAIR:-$HOME/mass-asset-keys/preview/program.json}"
SO="${MASS_SO:-$MASS_DIR/target/deploy/mass_asset_v1.so}"

[[ -f "$WALLET" ]] || { echo "ERROR: wallet not found: $WALLET" >&2; exit 1; }
[[ -f "$PROGRAM_KEYPAIR" ]] || { echo "ERROR: program keypair not found: $PROGRAM_KEYPAIR" >&2; exit 1; }

PROGRAM_ID="$(solana-keygen pubkey "$PROGRAM_KEYPAIR")"
WALLET_PUBKEY="$(solana-keygen pubkey "$WALLET")"
# Before anything is signed: the network and the target are the pinned ones.
require_network "$RPC" "$TESTNET_GENESIS" "X1 testnet"
[[ "$PROGRAM_ID" == "$PREVIEW_PROGRAM_ID" ]] || { echo "ERROR: $PROGRAM_KEYPAIR is $PROGRAM_ID, not the pinned preview id $PREVIEW_PROGRAM_ID" >&2; exit 1; }

if [[ -z "${MASS_SO:-}" ]]; then
  echo "[1/3] Host unit tests and SBF build"
  (cd "$MASS_DIR" && cargo test --quiet && cargo build-sbf)
else
  echo "[1/3] Using prebuilt binary $SO"
fi
[[ -f "$SO" ]] || { echo "ERROR: binary not found: $SO" >&2; exit 1; }
printf 'Binary: %s bytes, sha256 %s\n' "$(stat -c%s "$SO")" "$(sha256sum "$SO" | awk '{print $1}')"

EXISTS="$(account_state "$RPC" "$PROGRAM_ID")"
[[ "$EXISTS" != error ]] || { echo "ERROR: cannot read $PROGRAM_ID from $RPC (RPC error, not a missing account); not deploying" >&2; exit 1; }
if [[ "$EXISTS" == exists ]]; then
  AUTH="$(program_authority "$RPC" "$PROGRAM_ID")"
  [[ "$AUTH" == "$WALLET_PUBKEY" ]] || { echo "ERROR: $PROGRAM_ID has upgrade authority '$AUTH', not $WALLET_PUBKEY" >&2; exit 1; }
  echo "[2/3] Upgrading preview program $PROGRAM_ID in place"
  solana --url "$RPC" --keypair "$WALLET" program deploy "$SO" \
    --program-id "$PROGRAM_ID" --upgrade-authority "$WALLET"
else
  echo "[2/3] First deployment of preview program $PROGRAM_ID (upgrade authority $WALLET_PUBKEY)"
  solana --url "$RPC" --keypair "$WALLET" program deploy "$SO" \
    --program-id "$PROGRAM_KEYPAIR" --upgrade-authority "$WALLET"
fi

echo "[3/3] Deployed state"
for i in $(seq 1 20); do
  solana --url "$RPC" program show "$PROGRAM_ID" && break
  echo "  waiting for the RPC ($i/20)..."; sleep 3
done
echo
echo "Next: run the suite against the preview program:"
echo "  MASS_PROGRAM_ID=$PROGRAM_ID X1_RPC=$RPC WALLET=$WALLET tests/onchain/run.sh"
