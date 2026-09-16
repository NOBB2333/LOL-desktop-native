#!/usr/bin/env bash
# Direct `zig test` invocation for src/backend.zig, reconstructed from the
# backend_test_mod module graph in build.zig.
#
# Why this exists: `zig build test` goes through the pnpm shim and, in sandboxed
# agent sessions, intermittently fails with `unable to load '<file>': AccessDenied`
# while the compiler walks test blocks. Calling the compiler directly with the same
# module graph avoids the shim, and the global cache is kept inside the workspace
# because the default %LOCALAPPDATA%\zig cache is often unwritable there.
#
# In a normal terminal `zig build test` is fine; use this script when that fails.
set -u
cd "$(dirname "$0")/.." || exit 1

ZIG=/d/4_Code/.miseEnv/installs/zig/0.16.0/zig.exe
SDK=node_modules/@native-sdk/cli
SQLITE="$SDK/third_party/sqlite"

run() {
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
    "-Mbuild_options=.zig-cache/c/3ad8806beb176df27bad156e8694f7e8/options.zig" \
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
    --zig-lib-dir "D:/4_Code/.miseEnv/installs/zig/0.16.0/lib"
}

for attempt in $(seq 1 8); do
  run > .zig-cache/backend-test.log 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "backend tests passed on attempt $attempt"
    exit 0
  fi
  if ! grep -q "AccessDenied" .zig-cache/backend-test.log; then
    echo "backend tests failed (not a transient AccessDenied) on attempt $attempt"
    exit "$status"
  fi
  echo "attempt $attempt hit AccessDenied, retrying..."
done
echo "backend tests never got past AccessDenied"
exit 1
