#!/bin/sh
# Repeatable application checks; deliberately excludes live models/providers/OS grants.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
umask 077
output=${1:-"$repo_root/build/premodel-$(date -u +%Y%m%dT%H%M%SZ)-$$"}
if [ -e "$output" ]; then echo 'Choose a new evidence directory; existing results were preserved.' >&2; exit 1; fi
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd)
# An inherited developer environment must not turn this into a live test.
unset PUDDLE_CUA_DRIVER PUDDLE_CUA_LIVE PUDDLE_CUA_LIVE_URL PUDDLE_LIVE_AUDIO_FILE
unset PUDDLE_LIVE_INFERENCE_ADDRESS PUDDLE_LIVE_INFERENCE_KEY PUDDLE_LIVE_INFERENCE_MODEL
unset PUDDLE_FILESYSTEM_TESTS PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY
unset PUDDLE_LOAD_PROFILE PUDDLE_LOAD_ITERATIONS PUDDLE_LOAD_EXPORT_FIXTURE PUDDLE_LOAD_SAVE_BUDGET_MS
unset PUDDLE_GOOGLE_CLIENT_FILE PUDDLE_SIGNING_IDENTITY
export PUDDLE_LOAD_TESTS=1 PUDDLE_LOAD_OUTPUT_DIRECTORY="$output"
run() {
    name=$1; shift
    printf 'Checking %s…\n' "$name"
    if "$@" > "$output/$name.log" 2>&1; then
        printf 'PASS %s\n' "$name" | tee -a "$output/results.txt"
    else
        printf 'FAIL %s (see %s/%s.log)\n' "$name" "$output" "$name" | tee -a "$output/results.txt"
        tail -40 "$output/$name.log"
        exit 1
    fi
}
git rev-parse HEAD > "$output/base-commit.txt"
git diff --binary > "$output/working-tree.patch"
git ls-files --cached --others --exclude-standard -z -- Sources Tests scripts app .github docs | xargs -0 shasum -a 256 > "$output/source-sha256.txt"
run guards make guards
run debug env PUDDLE_LOAD_RUN=debug sh scripts/swift.sh test
run release env PUDDLE_LOAD_RUN=release sh scripts/swift.sh test -c release
run heavy env PUDDLE_LOAD_RUN=release PUDDLE_LOAD_PROFILE=heavy sh scripts/swift.sh test -c release --filter WorkspaceLoadTests
run endurance env PUDDLE_LOAD_RUN=release PUDDLE_LOAD_PROFILE=long PUDDLE_LOAD_ITERATIONS=1000 sh scripts/swift.sh test -c release --filter WorkspaceLoadTests
run build env PUDDLE_BUILD_CONFIGURATION=release sh scripts/build.sh
run bundle python3 scripts/verify-bundle.py
run whitespace git diff --check
printf 'Pre-model checks passed. Evidence: %s\n' "$output"
printf 'Live-model, provider, OS/hardware and public signing acceptance remain open.\n'
