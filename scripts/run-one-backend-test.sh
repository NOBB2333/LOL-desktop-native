#!/usr/bin/env bash
# 只跑 champion_ability_values 里带「乘积段」的用例，并把断言里的 JSON 打出来。
set -u
cd "$(dirname "$0")/.." || exit 1

ZIG=/d/4_Code/.miseEnv/installs/zig/0.16.0/zig.exe
SDK=node_modules/@native-sdk/cli
SQLITE="$SDK/third_party/sqlite"
BUILD_OPTIONS=$(ls -t .zig-cache/c/*/options.zig 2>/dev/null | head -1)
[ -z "$BUILD_OPTIONS" ] && { echo "missing options.zig" >&2; exit 1; }

"$ZIG" test \
  -j1 \
  -cflags -DSQLITE_THREADSAFE=2 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 \
    -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_UPDATE_HOOK \
    -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_DEFAULT_MEMSTATUS=0 \
    -- "$SQLITE/sqlite3.c" \
  -ODebug -I "$SQLITE" \
  --dep native_sdk --dep lcu --dep build_options --dep storage \
  "-Mroot=src/backend.zig" \
  -ODebug -I "$SQLITE" \
  --dep geometry --dep assets --dep app_dirs --dep trace --dep app_manifest \
    --dep diagnostics --dep platform_info --dep json --dep canvas \
  "-Mnative_sdk=$SDK/src/root.zig" \
  -ODebug "-Mlcu=src/lcu.zig" \
  "-Mbuild_options=$BUILD_OPTIONS" \
  -ODebug -I "$SQLITE" "-Mstorage=src/storage.zig" \
  -ODebug "-Mgeometry=$SDK/src/primitives/geometry/root.zig" \
  -ODebug "-Massets=$SDK/src/primitives/assets/root.zig" \
  -ODebug "-Mapp_dirs=$SDK/src/primitives/app_dirs/root.zig" \
  -ODebug "-Mtrace=$SDK/src/primitives/trace/root.zig" \
  -ODebug "-Mapp_manifest=$SDK/src/primitives/app_manifest/root.zig" \
  -ODebug "-Mdiagnostics=$SDK/src/primitives/diagnostics/root.zig" \
  -ODebug "-Mplatform_info=$SDK/src/primitives/platform_info/root.zig" \
  -ODebug "-Mjson=$SDK/src/primitives/json/root.zig" \
  -ODebug --dep geometry --dep json "-Mcanvas=$SDK/src/primitives/canvas/root.zig" \
  -lc --cache-dir .zig-cache --global-cache-dir .zig-cache/global --name test \
  --zig-lib-dir "D:/4_Code/.miseEnv/installs/zig/0.16.0/lib" \
  --test-filter "$1"
