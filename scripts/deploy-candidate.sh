#!/usr/bin/env bash
# Mass Asset v1 — CANDIDATE deployment on X1 mainnet under the FINAL program id, WITH an upgrade
# authority (release process: format2/RELEASE.md).
#
#   verifiable build → testnet rehearsal → THIS SCRIPT → full suite against the candidate on mainnet
#   → FLUX check against the candidate → finalize.sh (removes the upgrade authority) → re-check
#
# First run deploys the program. If a check or the suite fails, fix, rebuild verifiably and run this
# script again: it upgrades the candidate in place (same id, same authority). Nothing is final here.
#
# Refuses unless:
#   - the RPC serves X1 mainnet (genesis hash pinned in release/networks.env);
#   - the binary matches a clean verifiable build of the pinned public repository;
#   - TESTNET_LOG is a complete PASSED testnet run (pinned testnet genesis) of exactly this binary;
#   - the program id has the MAss prefix and, if a candidate record exists, is the recorded id.
#
# Environment:
#   PROGRAM_KEYPAIR  keypair of the final program id (MAss…); required. Back it up first.
#   WALLET           payer and upgrade authority (default: ~/.config/solana/id.json); a dedicated
#                    release wallet, used for nothing else until finalize.sh is done
#   X1_RPC           mainnet RPC endpoint (default: MAINNET_RPC from release/networks.env)
#   TESTNET_LOG      testnet rehearsal log (default: evidence/testnet-v1-rc-pass.log)
#   ID_PREFIX        required prefix of the program id (default: MAss)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/common.sh"
load_networks "$ROOT"
RPC="${X1_RPC:-$MAINNET_RPC}"
WALLET="${WALLET:-$HOME/.config/solana/id.json}"
ID_PREFIX="${ID_PREFIX:-MAss}"
TESTNET_LOG="${TESTNET_LOG:-$ROOT/evidence/testnet-v1-rc-pass.log}"
: "${PROGRAM_KEYPAIR:?set PROGRAM_KEYPAIR=/path/to/MAss…-keypair.json (back it up first)}"
CANDIDATE_RECORD="$ROOT/build/candidate.txt"

# Same lock as finalize.sh; no deploy or upgrade while a finalization attempt is open or done.
mkdir -p "$ROOT/build/finalize"
exec 9>"$ROOT/build/.finalize.lock"
flock -n 9 || { echo "ERROR: build/.finalize.lock is held (finalize.sh running?) — one release operation at a time" >&2; exit 1; }
for d in "$ROOT"/build/finalize/attempt-*; do
  [[ -f "$d/finalize-tx.json" ]] || continue
  if [[ ! -f "$d/CLOSED" ]]; then
    echo "ERROR: finalization attempt $(basename "$d") has a signed transaction and is still open; run finalize.sh (verify only) first" >&2; exit 1
  fi
  if grep -qx "closed: verified" "$d/CLOSED"; then
    echo "ERROR: the program was finalized ($(basename "$d")); no candidate deployment is possible" >&2; exit 1
  fi
done

[[ -f "$WALLET" ]] || { echo "ERROR: wallet not found: $WALLET" >&2; exit 1; }
[[ -f "$PROGRAM_KEYPAIR" ]] || { echo "ERROR: program keypair not found: $PROGRAM_KEYPAIR" >&2; exit 1; }
command -v solana-verify >/dev/null || { echo "ERROR: solana-verify not found" >&2; exit 1; }

echo "=== Pre-deployment checks ==="
require_network "$RPC" "$MAINNET_GENESIS" "X1 mainnet"
load_build_record "$ROOT"
echo "OK   binary = clean verifiable build of $BUILD_REPO @ $BUILD_COMMIT ($BUILD_HASH)"

PROGRAM_ID="$(solana-keygen pubkey "$PROGRAM_KEYPAIR")"
WALLET_PUBKEY="$(solana-keygen pubkey "$WALLET")"
[[ "$PROGRAM_ID" == "$ID_PREFIX"* ]] || { echo "ERROR: program id $PROGRAM_ID does not start with $ID_PREFIX" >&2; exit 1; }
if [[ -f "$CANDIDATE_RECORD" ]]; then
  REC_ID="$(record_field "$CANDIDATE_RECORD" program_id)"
  [[ "$REC_ID" == "$PROGRAM_ID" ]] || { echo "ERROR: build/candidate.txt is for $REC_ID, not $PROGRAM_ID; the release id does not change" >&2; exit 1; }
fi

# The testnet rehearsal of this exact binary against the pinned preview program must have passed.
# The frozen copy is what is checked, hashed and recorded.
TESTNET_ID="$PREVIEW_PROGRAM_ID"
[[ -f "$TESTNET_LOG" ]] || { echo "ERROR: testnet log not found: $TESTNET_LOG" >&2; exit 1; }
mkdir -p "$ROOT/build"; TESTNET_FROZEN="$ROOT/build/candidate-testnet-suite.log"
cp "$TESTNET_LOG" "$TESTNET_FROZEN"
TESTNET_SHA="$(sha256sum "$TESTNET_FROZEN" | cut -d" " -f1)"
if ! check_suite_log "$TESTNET_FROZEN" testnet "$TESTNET_GENESIS" "$TESTNET_ID" "$BUILD_HASH"; then
  echo "ERROR: $TESTNET_LOG is not a complete PASSED testnet run of this binary (RELEASE.md, step 3)" >&2; exit 1
fi

MODE="deploy"
EXISTS="$(account_state "$RPC" "$PROGRAM_ID")"
[[ "$EXISTS" != error ]] || { echo "ERROR: cannot read $PROGRAM_ID from $RPC (RPC error, not a missing account); not deploying" >&2; exit 1; }
if [[ "$EXISTS" == exists ]]; then
  AUTH="$(program_authority "$RPC" "$PROGRAM_ID")"
  if [[ "$AUTH" == "none" ]]; then
    echo "ERROR: $PROGRAM_ID is already final (no upgrade authority); nothing to do." >&2; exit 1
  elif [[ "$AUTH" == "$WALLET_PUBKEY" ]]; then
    MODE="upgrade"
  else
    echo "ERROR: $PROGRAM_ID exists with upgrade authority '$AUTH', not $WALLET_PUBKEY." >&2; exit 1
  fi
fi
BAL="$(solana --url "$RPC" balance "$WALLET_PUBKEY" --lamports | awk '{print $1}')"

cat <<INFO

=== MASS ASSET v1 — CANDIDATE ($MODE) ===
RPC:              $RPC (X1 mainnet, genesis $MAINNET_GENESIS)
Program id:       $PROGRAM_ID   (final id; stays upgradeable until finalize.sh)
Upgrade authority: $WALLET_PUBKEY
Binary:           $SO
Executable hash:  $BUILD_HASH   (verifiable build of $BUILD_REPO @ $BUILD_COMMIT, $BUILD_IMAGE)
Testnet rehearsal: $TESTNET_LOG (PASSED, program $TESTNET_ID)
Payer balance:    $BAL lamports
INFO
read -r -p "Type CANDIDATE to continue: " ANSWER
[[ "$ANSWER" == "CANDIDATE" ]] || { echo "Aborted."; exit 1; }

# A previous record no longer describes the deployment once it is upgraded.
rm -f "$CANDIDATE_RECORD"
solana --url "$RPC" --keypair "$WALLET" program deploy "$SO" --program-id "$PROGRAM_KEYPAIR" --upgrade-authority "$WALLET"

echo
echo "=== Post-deployment checks ==="
OK=1
require_network "$RPC" "$MAINNET_GENESIS" "X1 mainnet"
# One finalized snapshot of deployment state and bytecode (waits until the new deployment is finalized).
snapshot "$RPC" "$PROGRAM_ID" "$BUILD_HASH"
STATE="$SNAP_STATE"; ONCHAIN="$SNAP_HASH"
AUTH="${STATE##*authority=}"
[[ -n "$STATE" ]] && echo "OK   deployment (finalized): $STATE" || { echo "FAIL no consistent finalized snapshot of $PROGRAM_ID"; OK=0; }
[[ "$AUTH" == "$WALLET_PUBKEY" ]] && echo "OK   upgrade authority: $AUTH (candidate, upgradeable)" || { echo "FAIL upgrade authority: '$AUTH'"; OK=0; }
[[ "$ONCHAIN" == "$BUILD_HASH" ]] && echo "OK   on-chain executable hash == verifiable-build hash" || { echo "FAIL on-chain hash '$ONCHAIN' != $BUILD_HASH"; OK=0; }
(( OK )) || { echo "Candidate checks FAILED — no candidate record written; investigate before running the suite." >&2; exit 1; }

# Record written only after every check passed.
TMP="$(mktemp)"
{
  echo "program_id:         $PROGRAM_ID"
  echo "network:            X1 mainnet"
  echo "genesis:            $MAINNET_GENESIS"
  echo "rpc:                $RPC"
  echo "status:             candidate (upgradeable)"
  echo "deployment:         $STATE"
  echo "programdata:        $(state_programdata "$STATE")"
  echo "deployed_slot:      $(sed 's/.* slot=\([^ ]*\).*/\1/' <<<"$STATE")"
  echo "upgrade_authority:  $AUTH"
  echo "executable_hash:    $ONCHAIN"
  echo "source_repo:        $BUILD_REPO"
  echo "source_commit:      $BUILD_COMMIT"
  echo "build_image:        $BUILD_IMAGE"
  echo "testnet_log_sha256: $TESTNET_SHA   (build/candidate-testnet-suite.log, hashed before checking)"
  echo "deployed_at_utc:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TMP"
mv "$TMP" "$CANDIDATE_RECORD"
cat "$CANDIDATE_RECORD"
echo
echo "Next (RELEASE.md, steps 5–6):"
echo "  X1_NETWORK=mainnet X1_RPC=$RPC MASS_PROGRAM_ID=$PROGRAM_ID MASS_SO=$SO WALLET=$WALLET tests/onchain/run.sh"
echo "  then the FLUX check against $PROGRAM_ID, then scripts/finalize.sh"
