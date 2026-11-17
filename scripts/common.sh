# Shared helpers for the Mass Asset v1 release scripts (sourced, not executed).
#
# Pinned release parameters (networks, preview id, source repository, build image) live in
# release/networks.env, a committed and reviewed file. The scripts identify a network by its genesis
# hash, never by the RPC URL alone, and read on-chain state at commitment "finalized".

CM=finalized
MA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_networks() {  # load_networks <root>: sources release/networks.env, exits if a value is missing
  local f="$1/release/networks.env"
  [[ -f "$f" ]] || { echo "ERROR: $f not found" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$f"
  local v
  for v in MAINNET_RPC MAINNET_GENESIS TESTNET_RPC TESTNET_GENESIS PREVIEW_PROGRAM_ID; do
    [[ -n "${!v:-}" ]] || { echo "ERROR: $v is empty in $f (RELEASE.md, step 0)" >&2; exit 1; }
  done
}
require_build_pins() {  # SOURCE_REPO and a BUILD_IMAGE pinned by digest (after load_networks)
  [[ -n "${SOURCE_REPO:-}" ]] || { echo "ERROR: SOURCE_REPO is empty in release/networks.env" >&2; exit 1; }
  [[ "${BUILD_IMAGE:-}" == *@sha256:* ]] || { echo "ERROR: BUILD_IMAGE in release/networks.env must be pinned by digest (…@sha256:…; RELEASE.md, step 0)" >&2; exit 1; }
}

# Refuse to continue unless <rpc> serves the network with genesis hash <expected>.
require_network() {  # require_network <rpc> <expected genesis> <label>
  local got
  got="$(solana --url "$1" genesis-hash 2>/dev/null || true)"
  if [[ "$got" != "$2" ]]; then
    echo "ERROR: $1 is not $3: genesis hash '${got:-unavailable}', expected $2" >&2
    exit 1
  fi
  echo "OK   network: $3 (genesis $got via $1)"
}

# exists | absent | error — "absent" only on an explicit AccountNotFound, never on an RPC failure.
account_state() {  # account_state <rpc> <address>
  local out
  if out="$(solana --commitment "$CM" --url "$1" account "$2" --output json 2>&1)"; then
    echo exists
  elif grep -q "AccountNotFound" <<<"$out"; then
    echo absent
  else
    echo error
  fi
}

# One field of `solana program show` at commitment finalized ("Authority" is "none" once final).
program_field() {  # program_field <rpc> <program id> <field name>
  solana --commitment "$CM" --url "$1" program show "$2" 2>/dev/null | awk -F': *' -v k="$3" '$1==k{print $2}'
}
program_authority() { program_field "$1" "$2" "Authority"; }

# The deployment a run or a signature is bound to: ProgramData account, last deployment slot, authority.
# Every deploy or upgrade changes the slot. "?" in a field means it could not be read.
deployment_state() {  # deployment_state <rpc> <program id>  →  "programdata=… slot=… authority=…"
  local show pd slot auth
  show="$(solana --commitment "$CM" --url "$1" program show "$2" 2>/dev/null || true)"
  pd="$(awk -F': *' '$1=="ProgramData Address"{print $2}' <<<"$show")"
  slot="$(awk -F': *' '$1=="Last Deployed In Slot"{print $2}' <<<"$show")"
  auth="$(awk -F': *' '$1=="Authority"{print $2}' <<<"$show")"
  echo "programdata=${pd:-?} slot=${slot:-?} authority=${auth:-?}"
}
state_programdata() { sed 's/^programdata=\([^ ]*\).*/\1/' <<<"$1"; }

# Consistent finalized snapshot: the Program and ProgramData accounts from ONE getMultipleAccounts
# response at commitment finalized, and the executable hash of the bytecode in that same response
# (tests/onchain/snapshot.mjs). Sets SNAP_STATE ("programdata=… slot=… authority=…"), SNAP_HASH and
# SNAP_CONTEXT (response slot); empty on failure. With [expected hash] it retries until the snapshot has
# that hash (a node that has not caught up with a fresh upgrade).
snapshot() {  # snapshot <rpc> <program id> [expected hash]
  local rpc="$1" id="$2" want="${3:-}" elf out
  SNAP_STATE=""; SNAP_HASH=""; SNAP_CONTEXT=""
  [[ -d "$MA_ROOT/tests/onchain/node_modules/@solana/web3.js" ]] || { echo "ERROR: run 'npm ci' in tests/onchain (snapshot needs @solana/web3.js)" >&2; return 1; }
  elf="$(mktemp)"
  for i in 1 2 3 4 5 6 7 8; do
    if out="$(cd "$MA_ROOT/tests/onchain" && node snapshot.mjs "$rpc" "$id" "$elf" 2>/dev/null)"; then
      SNAP_STATE="$(sed -n 's/^state: //p' <<<"$out")"
      SNAP_CONTEXT="$(sed -n 's/^context_slot: //p' <<<"$out")"
      SNAP_HASH="$(solana-verify get-executable-hash "$elf" 2>/dev/null || true)"
      [[ -n "$SNAP_STATE" && -n "$SNAP_HASH" ]] && { [[ -z "$want" || "$SNAP_HASH" == "$want" ]] && break; }
    fi
    sleep 5
  done
  [[ -n "$SNAP_STATE" && -n "$SNAP_HASH" ]] || { SNAP_STATE=""; SNAP_HASH=""; }
  rm -f "$elf"
}

# Value of "key: value" in a record file: the first word, or (record_line) the rest of the line.
record_field() { awk -v k="$2:" '$1==k{print $2}' "$1"; }
record_line() { awk -v k="$2:" '$1==k{sub(/^[^:]*: */, ""); print}' "$1"; }

normalize_repo() { local u="${1%.git}"; echo "${u%/}"; }

# The commit is published: it is the tip of a branch or tag of the public repository.
commit_published() {  # commit_published <repo url> <commit>
  git ls-remote "$1" 2>/dev/null | awk '{print $1}' | grep -qx "$2"
}

# Verifiable-build record: the local binary must match it, and it must be a release build: fresh clean
# checkout of a published commit of the pinned public repository, image pinned by digest.
load_build_record() {  # sets SO BUILD_HASH BUILD_COMMIT BUILD_IMAGE_USED BUILD_REPO, exits on mismatch
  local root="$1"
  require_build_pins
  SO="$root/programs/mass-asset-v1/target/deploy/mass_asset_v1.so"
  local rec="$root/build/mass_asset_v1.sha256"
  [[ -f "$SO" && -f "$rec" ]] || { echo "ERROR: run scripts/verifiable-build.sh first" >&2; exit 1; }
  BUILD_HASH="$(record_field "$rec" executable_hash)"
  BUILD_COMMIT="$(record_field "$rec" commit)"
  BUILD_REPO="$(record_field "$rec" repo)"
  BUILD_IMAGE_USED="$(record_field "$rec" base_image)"
  if [[ "$(record_field "$rec" release_build)" != "yes" ]]; then
    echo "ERROR: $rec is not a release build (ALLOW_DIRTY); rebuild from a fresh checkout" >&2; exit 1
  fi
  if [[ "$(normalize_repo "$BUILD_REPO")" != "$(normalize_repo "$SOURCE_REPO")" ]]; then
    echo "ERROR: build is from '$BUILD_REPO', not the pinned source repository $SOURCE_REPO" >&2; exit 1
  fi
  if [[ "$BUILD_IMAGE_USED" != "$BUILD_IMAGE" ]]; then
    echo "ERROR: build image '$BUILD_IMAGE_USED' is not the pinned $BUILD_IMAGE" >&2; exit 1
  fi
  if ! commit_published "$SOURCE_REPO" "$BUILD_COMMIT"; then
    echo "ERROR: commit $BUILD_COMMIT is not a branch or tag tip of $SOURCE_REPO (not pushed, or the remote is unreachable)" >&2; exit 1
  fi
  local local_hash; local_hash="$(solana-verify get-executable-hash "$SO")"
  if [[ "$local_hash" != "$BUILD_HASH" ]]; then
    echo "ERROR: $SO hash $local_hash != recorded verifiable-build hash $BUILD_HASH" >&2
    echo "       (was the binary rebuilt with cargo build-sbf after the verifiable build?)" >&2
    exit 1
  fi
}

# A saved suite log (tests/onchain/run.sh) is ONE complete PASSED run against <id> on the network with
# <genesis>, with bytecode equal to <hash>, unchanged deployment and complete cleanup. Every binding line
# must occur exactly once, so a log that concatenates several runs is refused.
# Prints OK/FAIL lines; returns non-zero on any failure. <state>: expected "Deployment before:" value.
# Callers check (and later hash) a frozen copy of the log, never the original path.
check_suite_log() {  # check_suite_log <log> <network: mainnet|testnet> <genesis> <id> <hash> [state]
  local log="$1" net="$2" gen="$3" id="$4" hash="$5" state="${6:-}" ok=0
  [[ -f "$log" ]] || { echo "FAIL suite log not found: $log"; return 1; }
  once() { [[ "$(grep -c -- "$1" "$log")" == 1 ]]; }
  once '^=== MASS ASSET v1 (format 2) — ON-CHAIN CONFORMANCE SUITE ===$' && once '^Run: ' \
    && echo "OK   suite log: a single run ($(grep '^Run: ' "$log"))" || { echo "FAIL suite log is not exactly one run"; ok=1; }
  once "^Genesis: $gen\$" && once "^Network: X1 $net (pinned genesis)\$" && once '^Network: ' \
    && echo "OK   suite log: X1 $net, genesis $gen, pinned mode" || { echo "FAIL suite log is not a pinned X1 $net run (genesis $gen, X1_NETWORK=$net)"; ok=1; }
  local ph
  for ph in live issuer-b orphan; do
    once "^Finalized: all [0-9]* transactions of phase $ph\$" && echo "OK   suite log: phase $ph transactions finalized" || { echo "FAIL suite log: phase $ph transactions not confirmed finalized"; ok=1; }
  done
  once "^\[1/8\] Testing the deployed Mass Asset program $id " && echo "OK   suite log: deployed program $id" || { echo "FAIL suite log is not a run against $id"; ok=1; }
  once "^Bytecode: on-chain $hash " && once '^Bytecode: MATCH$' && echo "OK   suite log: Bytecode MATCH $hash" || { echo "FAIL suite log has no single Bytecode MATCH for $hash"; ok=1; }
  if [[ -n "$state" ]]; then
    once "^Deployment before: $state\$" && echo "OK   suite log: deployment $state" || { echo "FAIL suite log is not bound to deployment $state"; ok=1; }
  fi
  once '^Deployment: UNCHANGED$' && echo "OK   suite log: deployment unchanged during the run" || { echo "FAIL suite log: deployment changed or not checked during the run"; ok=1; }
  once '^Cleanup: OK$' && echo "OK   suite log: test programs closed" || { echo "FAIL suite log: cleanup incomplete"; ok=1; }
  [[ "$(tail -n 3 "$log" | grep -cx '=== ON-CHAIN SUITE PASSED ===')" == 1 ]] && once '^=== ON-CHAIN SUITE' \
    && echo "OK   suite log: PASSED" || { echo "FAIL suite log does not end with a single PASSED"; ok=1; }
  return $ok
}
