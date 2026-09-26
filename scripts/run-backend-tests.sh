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

# `build_options` 是 native-sdk 构建生成的模块文件，目录名是内容 hash：app.json 的
# version / 构建选项一变 hash 就变。以前这里写死过一个 hash，版本一升就直接
# `failed to check cache: ... options.zig FileNotFound`（表现像代码编不过，其实只是路径过期）。
# 现查最近生成的那一个；一个都没有时说明还没跑过 native-sdk 构建。
BUILD_OPTIONS=$(ls -t .zig-cache/c/*/options.zig 2>/dev/null | head -1)
if [ -z "$BUILD_OPTIONS" ]; then
  echo "missing .zig-cache/c/*/options.zig — 先跑一次 native-sdk 构建（会生成 build_options）再跑本脚本" >&2
  exit 1
fi

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
