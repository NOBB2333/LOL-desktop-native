#!/usr/bin/env sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIG="$ROOT/config/native.json"
TARGET="$(node -e 'console.log(require(process.argv[1]).package.target)' "$CONFIG")"
ARCHIVE_DISABLED=0
SINGLE_FILE="$(node -e 'console.log(require(process.argv[1]).package.singleFile !== false)' "$CONFIG")"
for ARG in "$@"; do
  case "$ARG" in
    windows|macos|linux) TARGET="$ARG" ;;
    --no-archive) ARCHIVE_DISABLED=1 ;;
    *) echo "unknown argument: $ARG" >&2; exit 2 ;;
  esac
done
SDK="$(node -e 'const c=require(process.argv[1]); console.log(c.nativeSdkPath)' "$CONFIG")"
case "$SDK" in /*) ;; *) SDK="$ROOT/$SDK" ;; esac
if [ ! -f "$SDK/build.zig" ]; then
  GLOBAL_SDK="$(npm root -g)/@native-sdk/cli"
  [ -f "$GLOBAL_SDK/build.zig" ] && SDK="$GLOBAL_SDK"
fi
test -f "$SDK/build.zig"
command -v node >/dev/null
command -v npm >/dev/null
command -v zig >/dev/null
node "$ROOT/scripts/sync-native-config.mjs"
cd "$ROOT"
zig build package "-Dpackage-target=$TARGET" "-Dplatform=$TARGET" "-Dnative-sdk-path=$SDK" -Dpackage-archive=false
PACKAGE_DIR="$ROOT/zig-out/package/lol-desktop-native-2.0.0-$TARGET-ReleaseFast"
if [ "$ARCHIVE_DISABLED" != 1 ] && [ "$SINGLE_FILE" = true ] && [ -d "$PACKAGE_DIR" ]; then
  BINARY="$PACKAGE_DIR/bin/lol-desktop-native"
  SINGLE_EXE="$ROOT/zig-out/package/lol-desktop-native"
  test -f "$BINARY"
  rm -f "$SINGLE_EXE" "$ROOT/zig-out/package"/*.zip
  cp "$BINARY" "$SINGLE_EXE"
  rm -rf "$PACKAGE_DIR"
  printf 'Single-file executable: %s/zig-out/package/lol-desktop-native\n' "$ROOT"
elif [ "$ARCHIVE_DISABLED" != 1 ] && [ -d "$PACKAGE_DIR" ] && command -v zip >/dev/null 2>&1; then
  ARCHIVE="$ROOT/zig-out/package/lol-desktop-native-2.0.0-$TARGET-ReleaseFast.zip"
  rm -f "$ARCHIVE"
  (cd "$PACKAGE_DIR" && zip -qr "$ARCHIVE" .)
  printf 'Package archive: %s\n' "$ARCHIVE"
else
  printf 'Package output: %s/zig-out/package\n' "$ROOT"
fi
