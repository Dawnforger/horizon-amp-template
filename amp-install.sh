#!/usr/bin/env bash
# AMP update stage: installs/updates Horizon into the instance and prepares the game files.
#   amp-install.sh <instance-base-dir> [tag]
set -euo pipefail
BASE=${1:?base dir}; TAG=${2:-latest}
cd "$BASE"
command -v python3 >/dev/null || { echo "python3 is required on the host (apt install python3)"; exit 1; }
args=(--dir "$BASE/horizon" --bin "$BASE/bin")
[ "$TAG" = latest ] || [ "$TAG" = nightly ] || args+=(--version "$TAG")
echo "Installing Horizon ($TAG)..."
curl -fsSL https://raw.githubusercontent.com/horizon-rust/horizon/main/packaging/server/install.sh | sh -s -- "${args[@]}"
# Game files: Minecraft 26.3 from Mojang (pinned + verified) -> horizon-prepare. Java 25 is fetched if missing.
HORIZON_FETCH_JAVA=1 HORIZON_PREP_WORK="$BASE/.prep" bash "$BASE/prepare-headless.sh" "$BASE/horizon/current"
echo "Horizon install complete."
