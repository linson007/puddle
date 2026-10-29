#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/module-cache"
action=${1:-build}
if [ "$#" -gt 0 ]; then shift; fi
exec swift "$action" --disable-sandbox --cache-path "$repo_root/.build/cache" \
    --config-path "$repo_root/.build/config" --security-path "$repo_root/.build/security" \
    -Xswiftc -module-cache-path -Xswiftc "$repo_root/.build/module-cache" "$@"
