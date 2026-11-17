#!/usr/bin/env bash
# Mass Asset v1 — verifiable (deterministic) build.
#
# Builds programs/mass-asset-v1 inside the solana-verify Docker image, so that anyone
# can rebuild the same commit and obtain the same executable hash.
#
# Output:
#   programs/mass-asset-v1/target/deploy/mass_asset_v1.so   (the binary to test and deploy)
#   build/mass_asset_v1.sha256                               (executable hash + build metadata)
#
# Release build (default): refuses unless
#   - the tree is a FRESH checkout: no change (tracked or untracked) and no target/ from an earlier build;
#   - origin is SOURCE_REPO and HEAD is the tip of a branch or tag there (the commit is published);
#   - the image is BUILD_IMAGE from release/networks.env, pinned by digest.
# ALLOW_DIRTY=1 builds anyway for development; the record says release_build: no and every release
# script refuses it.
#
# Requirements: Docker, `cargo install solana-verify`, network access to SOURCE_REPO.
# The image must ship a Solana toolchain new enough for the locked dependencies
# (edition 2024 requires cargo >= 1.85).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRAM_DIR="$ROOT/programs/mass-asset-v1"
SO="$PROGRAM_DIR/target/deploy/mass_asset_v1.so"
OUT_DIR="$ROOT/build"
OUT="$OUT_DIR/mass_asset_v1.sha256"

command -v docker >/dev/null || { echo "ERROR: Docker is not installed or not on PATH." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not running (start Docker Desktop / dockerd)." >&2; exit 1; }
command -v solana-verify >/dev/null || { echo "ERROR: solana-verify not found. Install: cargo install solana-verify" >&2; exit 1; }

source "$ROOT/scripts/common.sh"
load_networks "$ROOT"
DEV="${ALLOW_DIRTY:-0}"
PROBLEMS=()
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || { COMMIT=unknown; PROBLEMS+=("not a git checkout"); }
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || { REPO=unknown; PROBLEMS+=("no origin remote"); }
if STATUS="$(git -C "$ROOT" status --porcelain --untracked-files=all 2>&1)"; then
  [[ -z "$STATUS" ]] || PROBLEMS+=("uncommitted changes:"$'\n'"$STATUS")
else
  PROBLEMS+=("git status failed: $STATUS")
fi
[[ ! -e "$PROGRAM_DIR/target" ]] || PROBLEMS+=("programs/mass-asset-v1/target exists (not a fresh checkout)")
[[ "$(normalize_repo "$REPO")" == "$(normalize_repo "${SOURCE_REPO:-}")" ]] || PROBLEMS+=("origin $REPO is not SOURCE_REPO ${SOURCE_REPO:-}")
commit_published "${SOURCE_REPO:-}" "$COMMIT" || PROBLEMS+=("$COMMIT is not a branch or tag tip of ${SOURCE_REPO:-} (not pushed, or unreachable)")
IMAGE="${BUILD_IMAGE:-}"
[[ "$IMAGE" == *@sha256:* ]] || PROBLEMS+=("BUILD_IMAGE in release/networks.env is not pinned by digest")
RELEASE=yes
if (( ${#PROBLEMS[@]} )); then
  if [[ "$DEV" != 1 ]]; then
    echo "ERROR: not a release build:" >&2; printf '  - %s\n' "${PROBLEMS[@]}" >&2
    echo "(ALLOW_DIRTY=1 builds anyway for development; the release scripts will refuse the result.)" >&2
    exit 1
  fi
  echo "WARNING: ALLOW_DIRTY=1 — not a release build:" >&2; printf '  - %s\n' "${PROBLEMS[@]}" >&2
  RELEASE=no
fi

echo "== Verifiable build of $COMMIT =="
BUILD_ARGS=(--library-name mass_asset_v1)
[[ -n "$IMAGE" ]] && BUILD_ARGS+=(--base-image "$IMAGE")
(cd "$PROGRAM_DIR" && solana-verify build "${BUILD_ARGS[@]}")

# The Docker build may leave target/ owned by root; give it back to the current user.
if [[ ! -w "$PROGRAM_DIR/target" ]]; then
  echo "target/ is not writable (owned by Docker/root); fixing ownership with sudo..."
  sudo chown -R "$(id -u):$(id -g)" "$PROGRAM_DIR/target"
fi
HASH="$(solana-verify get-executable-hash "$SO")"
mkdir -p "$OUT_DIR"
{
  echo "program:          mass_asset_v1"
  echo "repo:             $REPO"
  echo "commit:           $COMMIT"
  echo "release_build:    $RELEASE"
  echo "executable_hash:  $HASH"
  echo "size_bytes:       $(stat -c%s "$SO")"
  echo "solana_verify:    $(solana-verify --version 2>/dev/null || echo unknown)"
  echo "base_image:       ${IMAGE:-auto}"
  echo "built_at_utc:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$OUT"

echo
echo "Binary: $SO"
echo "Note: executable_hash (solana-verify) ignores trailing padding, so it differs from a plain sha256sum of the file."
echo "Next: run the on-chain suite against THIS binary:"
echo "  RELEASE.md, step 3 (testnet rehearsal of this binary)"
