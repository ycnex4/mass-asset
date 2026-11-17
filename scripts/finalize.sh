#!/usr/bin/env bash
# Mass Asset v1 — FINALIZE the mainnet candidate: remove its upgrade authority (release process:
# format2/RELEASE.md). THIS IS IRREVERSIBLE: afterwards the program can never be upgraded or closed,
# and its rent is locked.
#
# The program id comes from build/candidate.txt (written by deploy-candidate.sh after its checks passed).
#
# Before signing, refuses unless, all at once:
#   - the RPC serves X1 mainnet (genesis hash pinned in release/networks.env);
#   - the binary matches a release verifiable build, and the candidate record is for that build;
#   - one finalized snapshot (Program + ProgramData in a single response, bytecode from the same
#     response) equals the recorded deployment, with authority = WALLET and hash = build hash;
#   - the FROZEN copies (build/finalize/) of the suite log and the FLUX log — the files that are checked
#     are the files that are hashed — are single pinned-mainnet PASSED runs bound to that deployment.
# The intent (log hashes, deployment, hash) is written to build/finalize-intent.txt before signing.
# After the operator types FINALIZE, the snapshot is taken again; any change aborts.
#
# One release operation at a time: the whole run holds an exclusive lock (build/.finalize.lock).
# Every attempt has its own directory build/finalize/attempt-<time>-<pid>/ (frozen logs, intent,
# transaction record, outputs); nothing in an earlier attempt is ever deleted or overwritten.
#
# The transaction (SetAuthority(None) on ProgramData) is built and signed by tests/onchain/finalize-tx.mjs,
# which records its signature, blockhash and the intent hash in the attempt's finalize-tx.json BEFORE
# sending and then reads the result from the network only. An attempt with a transaction record stays
# OPEN until it is closed by evidence; while an attempt is open, this script only verifies it and never
# signs again. An open attempt is closed:
#   - VERIFIED: transaction finalized, err null, exactly the expected instruction, signature and
#     blockhash; post-checks pass (snapshot context at or after the transaction slot) → deployment.txt;
#   - NOT-EXECUTED / FAILED: blockhash expired with the authority unchanged, or finalized with an error,
#     AND a full finalized snapshot (same ProgramData, slot, authority, bytecode) taken from a context at
#     or after the check slot → a new attempt is allowed on the next run.
# Anything else leaves the attempt open with an UNVERIFIED record; run the script again later.
#
# Environment:
#   WALLET       current upgrade authority (default: ~/.config/solana/id.json); the dedicated release
#                wallet — no other operation may use it while this runs
#   X1_RPC       mainnet RPC endpoint (default: MAINNET_RPC from release/networks.env)
#   PROGRAM_ID   optional; if set, must equal the id in build/candidate.txt
#   SUITE_LOG    suite log of the candidate run (default: tests/onchain/onchain.log)
#   FLUX_LOG     FLUX mainnet check log (default: evidence/flux-mainnet-check.log)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/common.sh"
load_networks "$ROOT"
RPC="${X1_RPC:-$MAINNET_RPC}"
WALLET="${WALLET:-$HOME/.config/solana/id.json}"
SUITE_LOG="${SUITE_LOG:-$ROOT/tests/onchain/onchain.log}"
FLUX_LOG="${FLUX_LOG:-$ROOT/evidence/flux-mainnet-check.log}"
CANDIDATE_RECORD="$ROOT/build/candidate.txt"
DEPLOY_RECORD="$ROOT/build/deployment.txt"
ATTEMPTS="$ROOT/build/finalize"

mkdir -p "$ATTEMPTS"
exec 9>"$ROOT/build/.finalize.lock"
flock -n 9 || { echo "ERROR: another finalize.sh holds build/.finalize.lock — one release operation at a time" >&2; exit 1; }

[[ -f "$WALLET" ]] || { echo "ERROR: wallet not found: $WALLET" >&2; exit 1; }
command -v solana-verify >/dev/null || { echo "ERROR: solana-verify not found" >&2; exit 1; }
[[ -f "$CANDIDATE_RECORD" ]] || { echo "ERROR: $CANDIDATE_RECORD not found (run deploy-candidate.sh)" >&2; exit 1; }
REC_ID="$(record_field "$CANDIDATE_RECORD" program_id)"
if [[ -n "${PROGRAM_ID:-}" && "$PROGRAM_ID" != "$REC_ID" ]]; then
  echo "ERROR: PROGRAM_ID=$PROGRAM_ID differs from the candidate record ($REC_ID)" >&2; exit 1
fi
PROGRAM_ID="$REC_ID"
REC_STATE="$(record_line "$CANDIDATE_RECORD" deployment)"
REC_PD="$(state_programdata "$REC_STATE")"
CANDIDATE_SHA="$(sha256sum "$CANDIDATE_RECORD" | cut -d' ' -f1)"
WALLET_PUBKEY="$(solana-keygen pubkey "$WALLET")"
require_network "$RPC" "$MAINNET_GENESIS" "X1 mainnet"
load_build_record "$ROOT"
OK=1
check() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; OK=0; fi; }
json_field() { sed -n "s/.*\"$2\": *\"\\{0,1\\}\\([^\",]*\\)\"\\{0,1\\}.*/\\1/p" "$1" | head -n1; }

# A verified attempt means the program is final: never start anything new; only (re)publish its record.
for d in "$ATTEMPTS"/attempt-*; do
  [[ -f "$d/CLOSED" ]] && grep -qx "closed: verified" "$d/CLOSED" || continue
  [[ -f "$d/deployment.txt" ]] || { echo "ERROR: $d is closed as verified but has no deployment.txt; investigate" >&2; exit 1; }
  if ! cmp -s "$d/deployment.txt" "$DEPLOY_RECORD"; then
    cp "$d/deployment.txt" "$DEPLOY_RECORD.tmp.$$" && mv -f "$DEPLOY_RECORD.tmp.$$" "$DEPLOY_RECORD"
    echo "Published build/deployment.txt from the verified attempt $(basename "$d") (no signing)."
  fi
  echo "The program is already finalized and verified ($(basename "$d")); nothing to do."
  exit 0
done

# Open attempts: a transaction record without a closing marker.
OPEN=()
for d in "$ATTEMPTS"/attempt-*; do
  [[ -d "$d" && -f "$d/finalize-tx.json" ]] || continue
  [[ -f "$d/CLOSED" ]] || OPEN+=("$d")
done
(( ${#OPEN[@]} <= 1 )) || { echo "ERROR: more than one open attempt (${OPEN[*]}); investigate manually" >&2; exit 1; }

if (( ${#OPEN[@]} == 1 )); then
  A="${OPEN[0]}"
  echo "=== Recovery of $A — verifying only, never signing ==="
  TXREC="$A/finalize-tx.json"; INTENT="$A/finalize-intent.txt"
  [[ -f "$INTENT" ]] || { echo "ERROR: $TXREC without $INTENT; investigate manually" >&2; exit 1; }
  SUITE_SHA="$(record_field "$INTENT" suite_log_sha256)"; FLUX_SHA="$(record_field "$INTENT" flux_log_sha256)"
  # Every record of the attempt must describe this candidate.
  check "intent ↔ candidate: program, deployment, candidate record hash" \
    '[[ "$(record_field "$INTENT" program_id)" == "$PROGRAM_ID" && "$(record_line "$INTENT" deployment)" == "$REC_STATE" && "$(record_field "$INTENT" candidate_sha256)" == "$CANDIDATE_SHA" ]]'
  check "transaction record ↔ intent ↔ candidate: program, ProgramData, authority, intent hash" \
    '[[ "$(json_field "$TXREC" program)" == "$PROGRAM_ID" && "$(json_field "$TXREC" programdata)" == "$REC_PD" && "$(json_field "$TXREC" authority)" == "$WALLET_PUBKEY" && "$(json_field "$TXREC" intent_sha256)" == "$(sha256sum "$INTENT" | cut -d" " -f1)" ]]'
  (( OK )) || { echo "Recovery records do not belong together — not verifying; investigate manually." >&2; exit 1; }
  MODE=verify
else
  A="$ATTEMPTS/attempt-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir "$A"
  TXREC="$A/finalize-tx.json"; INTENT="$A/finalize-intent.txt"
  echo "=== Pre-finalize checks (attempt $A) ==="
  check "candidate record: genesis $MAINNET_GENESIS" '[[ "$(record_field "$CANDIDATE_RECORD" genesis)" == "$MAINNET_GENESIS" ]]'
  check "candidate record: build $BUILD_HASH from $BUILD_COMMIT" \
    '[[ "$(record_field "$CANDIDATE_RECORD" executable_hash)" == "$BUILD_HASH" && "$(record_field "$CANDIDATE_RECORD" source_commit)" == "$BUILD_COMMIT" ]]'
  check "candidate record: authority $WALLET_PUBKEY" '[[ "$REC_STATE" == *" authority=$WALLET_PUBKEY" ]]'
  snapshot "$RPC" "$PROGRAM_ID" "$BUILD_HASH"
  check "finalized snapshot (context slot ${SNAP_CONTEXT:-?}) = recorded deployment: ${SNAP_STATE:-unavailable}" '[[ "$SNAP_STATE" == "$REC_STATE" ]]'
  check "on-chain executable hash (same response) == verifiable-build hash ($BUILD_HASH)" '[[ "$SNAP_HASH" == "$BUILD_HASH" ]]'

  # Freeze first; check and hash the frozen copies only.
  [[ -f "$SUITE_LOG" ]] || { echo "ERROR: suite log not found: $SUITE_LOG" >&2; exit 1; }
  [[ -f "$FLUX_LOG" ]] || { echo "ERROR: FLUX check log not found: $FLUX_LOG" >&2; exit 1; }
  cp "$SUITE_LOG" "$A/mainnet-suite.log"; cp "$FLUX_LOG" "$A/flux-mainnet-check.log"
  FROZEN_FLUX="$A/flux-mainnet-check.log"
  SUITE_SHA="$(sha256sum "$A/mainnet-suite.log" | cut -d' ' -f1)"; FLUX_SHA="$(sha256sum "$FROZEN_FLUX" | cut -d' ' -f1)"
  echo "--- suite log (frozen copy of $SUITE_LOG, sha256 $SUITE_SHA)"
  check_suite_log "$A/mainnet-suite.log" mainnet "$MAINNET_GENESIS" "$PROGRAM_ID" "$BUILD_HASH" "$REC_STATE" || OK=0
  echo "--- FLUX check log (frozen copy of $FLUX_LOG, sha256 $FLUX_SHA)"
  fonce() { [[ "$(grep -c -- "$1" "$FROZEN_FLUX")" == 1 ]]; }
  check "FLUX log: a single run" 'fonce "^Run: " && fonce "^=== FLUX MAINNET CHECK"'
  check "FLUX log: pinned X1 mainnet, genesis" 'fonce "^Genesis: $MAINNET_GENESIS\$" && fonce "^Network: X1 mainnet (pinned genesis)\$" && fonce "^Network: "'
  check "FLUX log: Mass Asset program $PROGRAM_ID" 'fonce "^Mass Asset program: $PROGRAM_ID\$"'
  check "FLUX log: Mass Asset deployment $REC_STATE" 'fonce "^Mass Asset deployment before: $REC_STATE\$"'
  check "FLUX log: Mass Asset bytecode $BUILD_HASH" 'fonce "^Mass Asset bytecode: $BUILD_HASH\$"'
  check "FLUX log: Mass Asset unchanged during the check" 'fonce "^Mass Asset deployment: UNCHANGED\$"'
  check "FLUX log: transactions finalized" 'fonce "^Finalized: all [0-9]* transactions\$"'
  check "FLUX log: PASSED" '[[ "$(tail -n 3 "$FROZEN_FLUX" | grep -cx "=== FLUX MAINNET CHECK PASSED ===")" == 1 ]]'
  (( OK )) || { echo "Pre-finalize checks FAILED — not finalizing (attempt $A kept, no transaction)." >&2; exit 1; }

  {
    echo "program_id:        $PROGRAM_ID"
    echo "genesis:           $MAINNET_GENESIS"
    echo "deployment:        $REC_STATE"
    echo "candidate_sha256:  $CANDIDATE_SHA"
    echo "snapshot_context:  $SNAP_CONTEXT"
    echo "executable_hash:   $BUILD_HASH"
    echo "source_commit:     $BUILD_COMMIT"
    echo "suite_log_sha256:  $SUITE_SHA"
    echo "flux_log_sha256:   $FLUX_SHA"
    echo "checked_at_utc:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$INTENT"
  # Durable before signing (power loss): the intent and the frozen logs it hashes, the attempt directory and
  # its parent. finalize-tx.json binds itself to the intent by sha256.
  sync -- "$A/mainnet-suite.log" "$A/flux-mainnet-check.log" "$INTENT" "$A" "$ATTEMPTS" \
    || { echo "ERROR: could not sync the intent and frozen logs of $A; not signing" >&2; exit 1; }
  echo "Evidence frozen before signing: $INTENT"

  cat <<INFO

=== MASS ASSET v1 — FINALIZE (IRREVERSIBLE) ===
RPC:              $RPC (X1 mainnet, genesis $MAINNET_GENESIS)
Program id:       $PROGRAM_ID
Deployment:       $REC_STATE
Executable hash:  $BUILD_HASH   (verifiable build of $BUILD_REPO @ $BUILD_COMMIT, $BUILD_IMAGE)
The upgrade authority $WALLET_PUBKEY will be removed: the program can never be changed or closed.
INFO
  read -r -p "Type FINALIZE to continue: " ANSWER
  [[ "$ANSWER" == "FINALIZE" ]] || { echo "Aborted (attempt $A kept, no transaction)."; exit 1; }

  echo "Re-checking the deployment before signing..."
  require_network "$RPC" "$MAINNET_GENESIS" "X1 mainnet"
  snapshot "$RPC" "$PROGRAM_ID" "$BUILD_HASH"
  if [[ "$SNAP_STATE" != "$REC_STATE" || "$SNAP_HASH" != "$BUILD_HASH" ]]; then
    echo "ERROR: the deployment changed since the checks (${SNAP_STATE:-unavailable}, hash ${SNAP_HASH:-unavailable}) — not finalizing." >&2; exit 1
  fi
  echo "OK   unchanged at finalized (context slot $SNAP_CONTEXT): $SNAP_STATE"
  echo
  echo "Signing and sending SetAuthority(None); the signature is recorded before sending."
  # Everything of the attempt is on disk before anything is signed (power loss).
  sync "$A"/* "$A" "$ATTEMPTS"
  MODE=send
fi

# finalize-tx.mjs exit codes: 0 ok, 3 not executed (blockhash expired, authority unchanged), 4
# undetermined, 5 unexpected transaction / record, 6 final by state but transaction not retrievable,
# 7 finalized with an error.
# The output of THIS run only decides the outcome (each run has its own file).
RUN_OUT="$A/finalize-tx.$(date -u +%Y%m%dT%H%M%SZ)-$$.$MODE.out"
set +e
if [[ "$MODE" == verify ]]; then
  (cd "$ROOT/tests/onchain" && node finalize-tx.mjs verify "$RPC" "$TXREC") | tee "$RUN_OUT"
else
  (cd "$ROOT/tests/onchain" && node finalize-tx.mjs send "$RPC" "$WALLET" "$PROGRAM_ID" "$TXREC" "$(sha256sum "$INTENT" | cut -d' ' -f1)") | tee "$RUN_OUT"
fi
PS=("${PIPESTATUS[@]}"); TXRC="${PS[0]}"; TEERC="${PS[1]:-1}"
set -e
sync "$A"/* "$A" 2>/dev/null || true
if [[ -f "$TXREC" ]] && { [[ "$TEERC" != 0 ]] || [[ ! -s "$RUN_OUT" ]]; }; then
  { echo "result: output of this run not captured (tee rc $TEERC, node rc $TXRC)"; echo "run_out: $RUN_OUT"
    echo "at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$A/UNVERIFIED.txt"
  echo "ERROR: the result of this run could not be recorded (tee rc $TEERC). Attempt $A stays OPEN; run finalize.sh again — it only verifies." >&2
  exit 1
fi
[[ -f "$TXREC" ]] || { echo "ERROR: finalize-tx.mjs stopped before recording a transaction (rc $TXRC); nothing was sent. Attempt $A has no transaction." >&2; exit 1; }
SIG="$(json_field "$TXREC" signature)"
# grep exits 1 when nothing matches; under set -e/pipefail that must not end the script here — an absent
# result goes to the OPEN/UNVERIFIED branch below.
RESULT="$(grep '^FINALIZE_TX \(OK\|NOT EXECUTED\|EXECUTED WITH ERROR\|UNEXPECTED\|UNDETERMINED\|STATE FINAL\|BAD RECORD\)' "$RUN_OUT" | tail -n1 || true)"
is_slot() { [[ "$1" =~ ^[0-9]+$ ]]; }
if [[ -z "$RESULT" ]]; then
  { echo "result: no final FINALIZE_TX line in this run's output (node rc $TXRC)"; echo "run_out: $RUN_OUT"
    echo "at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$A/UNVERIFIED.txt"
  echo "ERROR: this run produced no final result line. Attempt $A stays OPEN; run finalize.sh again — it only verifies." >&2
  exit 1
fi

# Closing an attempt without success needs a full finalized snapshot proving nothing changed, taken
# from a context at or after the slot where the outcome was established.
close_unchanged() {  # close_unchanged <reason> <min context slot>
  if ! is_slot "${2:-}"; then
    echo "No valid slot in this run's result ('${2:-}'); attempt $A stays OPEN." >&2
    cp "$RUN_OUT" "$A/UNVERIFIED.txt"; exit 1
  fi
  snapshot "$RPC" "$PROGRAM_ID" "$BUILD_HASH"
  if [[ "$SNAP_STATE" == "$REC_STATE" && "$SNAP_HASH" == "$BUILD_HASH" ]] && is_slot "$SNAP_CONTEXT" && (( SNAP_CONTEXT >= $2 )); then
    { echo "closed: $1"; echo "signature: $SIG"; echo "result: $RESULT"
      echo "snapshot: $SNAP_STATE hash=$SNAP_HASH context_slot=$SNAP_CONTEXT"
      echo "closed_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$A/CLOSED.tmp.$$"
    mv -f "$A/CLOSED.tmp.$$" "$A/CLOSED"
    echo "Attempt closed ($1): the deployment is unchanged at finalized (context $SNAP_CONTEXT ≥ $2). Run finalize.sh again for a new attempt."
    exit 1
  fi
  echo "Cannot prove that nothing changed (snapshot ${SNAP_STATE:-unavailable}, hash ${SNAP_HASH:-?}, context ${SNAP_CONTEXT:-?} vs ≥ $2)." >&2
  echo "Attempt $A stays OPEN; run finalize.sh again later — it only verifies." >&2
  cp "$RUN_OUT" "$A/UNVERIFIED.txt"; exit 1
}
case "$TXRC" in
  0) ;;
  3) close_unchanged "not executed (blockhash expired, authority unchanged)" "$(sed -n 's/.*expired_check_slot=\([0-9]*\).*/\1/p' <<<"$RESULT")";;
  7) close_unchanged "executed with an error" "$(sed -n 's/.* slot=\([0-9]*\) .*/\1/p' <<<"$RESULT")";;
  4) echo "Result undetermined. Attempt $A stays OPEN; do NOT sign anything — run finalize.sh again later." >&2
     cp "$RUN_OUT" "$A/UNVERIFIED.txt"; exit 1;;
  *) echo "Unexpected outcome (rc $TXRC): $RESULT. Attempt $A stays OPEN; investigate." >&2;;
esac
TXSLOT="$(sed -n 's/.* slot=\([0-9]*\) .*/\1/p' <<<"$RESULT")"

echo
echo "=== Post-finalize checks ==="
OK=1
check "finalization transaction $SIG: finalized, err null, SetAuthority(None), signature and blockhash as recorded" '[[ "$TXRC" == 0 ]] && is_slot "$TXSLOT"'
snapshot "$RPC" "$PROGRAM_ID" "$BUILD_HASH"
EXPECTED_FINAL="${REC_STATE% authority=*} authority=none"
check "finalized snapshot context ${SNAP_CONTEXT:-?} ≥ transaction slot ${TXSLOT:-?}" 'is_slot "$SNAP_CONTEXT" && is_slot "$TXSLOT" && (( SNAP_CONTEXT >= TXSLOT ))'
check "snapshot: ${SNAP_STATE:-unavailable} (same ProgramData and slot, authority none)" '[[ "$SNAP_STATE" == "$EXPECTED_FINAL" ]]'
check "on-chain executable hash == verifiable-build hash" '[[ "$SNAP_HASH" == "$BUILD_HASH" ]]'
check "frozen logs unchanged since the intent" '[[ "$(sha256sum "$A/mainnet-suite.log" | cut -d" " -f1)" == "$SUITE_SHA" && "$(sha256sum "$A/flux-mainnet-check.log" | cut -d" " -f1)" == "$FLUX_SHA" ]]'

OUT="$A/deployment.txt"; (( OK )) || OUT="$A/UNVERIFIED.txt"
{
  echo "program_id:          $PROGRAM_ID"
  echo "network:             X1 mainnet"
  echo "genesis:             $MAINNET_GENESIS"
  echo "rpc:                 $RPC"
  if (( OK )); then echo "status:              final (immutable), verified"; else echo "status:              POST-FINALIZE CHECKS FAILED"; fi
  echo "deployment:          ${SNAP_STATE:-unavailable}"
  echo "snapshot_context:    ${SNAP_CONTEXT:-unavailable}"
  echo "executable_hash:     ${SNAP_HASH:-unavailable}"
  echo "source_repo:         $BUILD_REPO"
  echo "source_commit:       $BUILD_COMMIT"
  echo "build_image:         $BUILD_IMAGE"
  echo "finalize_signature:  $SIG"
  echo "finalize_slot:       ${TXSLOT:-unavailable}"
  echo "finalize_result:     $RESULT"
  echo "attempt:             $(basename "$A")"
  echo "suite_log_sha256:    $SUITE_SHA"
  echo "flux_log_sha256:     $FLUX_SHA"
  echo "intent_sha256:       $(sha256sum "$INTENT" | cut -d' ' -f1)"
  echo "candidate_sha256:    $CANDIDATE_SHA"
  echo "recorded_at_utc:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT"
cat "$OUT"
(( OK )) || { echo "Post-finalize checks FAILED — $OUT; attempt stays OPEN; do not publish; run again later or investigate." >&2; exit 1; }
# Publish first (atomic rename), then close: a crash in between leaves the attempt open, and the next run
# verifies it again (read-only) and publishes; a crash after closing is repaired by the verified-attempt
# check at the start.
cp "$OUT" "$DEPLOY_RECORD.tmp.$$" && mv -f "$DEPLOY_RECORD.tmp.$$" "$DEPLOY_RECORD"
{ echo "closed: verified"; echo "signature: $SIG"; echo "closed_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$A/CLOSED.tmp.$$"
mv -f "$A/CLOSED.tmp.$$" "$A/CLOSED"
echo
echo "Done. Copy build/mass_asset_v1.sha256, build/candidate.txt, build/candidate-testnet-suite.log,"
echo "build/deployment.txt and the whole build/finalize/ directory into evidence/ (RELEASE.md, step 8)."
