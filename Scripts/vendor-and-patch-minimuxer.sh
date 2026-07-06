#!/usr/bin/env bash
# vendor-and-patch-minimuxer.sh
#
# ROOT CAUSE: SideStore/MinimuxerPackage@7a73cc7 vendors a swift-bridge-generated
# minimuxer.h that defines `__swift_bridge__$ResultVoidAndErrors` (Tag enum +
# Fields union + struct typedef) FIVE separate times in the same header, once
# per Rust source file that returns that Result type. That's malformed C and
# fails on any compiler/Xcode version - it is not caused by Explicit Modules,
# Xcode 26, or anything in OpenSideloader itself.
#
# This script vendors MinimuxerPackage locally, patches the duplicate type
# definitions out of minimuxer.h (both arch slices), and lays out a local SPM
# package you can reference with `.package(path:)` instead of the broken
# remote git revision - so you're no longer at the mercy of upstream's header
# generator.
#
# Usage: ./vendor-and-patch-minimuxer.sh [output_dir]
set -euo pipefail

OUT_DIR="${1:-Vendor/MinimuxerPackage}"
PIN_REVISION="7a73cc752eb4e1efcbda260d0854f3f3a3c8436d"
UPSTREAM_URL="https://github.com/SideStore/MinimuxerPackage.git"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Cloning $UPSTREAM_URL @ $PIN_REVISION"
git clone --quiet "$UPSTREAM_URL" "$WORK_DIR/MinimuxerPackage"
git -C "$WORK_DIR/MinimuxerPackage" checkout --quiet "$PIN_REVISION"

echo "==> Patching duplicate __swift_bridge__\$ResultVoidAndErrors definitions"
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  header="$WORK_DIR/MinimuxerPackage/RustXcframework.xcframework/$slice/Headers/minimuxer.h"
  python3 - "$header" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as fh:
    content = fh.read()

block_re = re.compile(
    r"typedef enum __swift_bridge__\$ResultVoidAndErrors\$Tag \{__swift_bridge__\$ResultVoidAndErrors\$ResultOk, __swift_bridge__\$ResultVoidAndErrors\$ResultErr\} __swift_bridge__\$ResultVoidAndErrors\$Tag;\n"
    r"union __swift_bridge__\$ResultVoidAndErrors\$Fields \{struct __swift_bridge__\$MinimuxerError err;\};\n"
    r"typedef struct __swift_bridge__\$ResultVoidAndErrors\{__swift_bridge__\$ResultVoidAndErrors\$Tag tag; union __swift_bridge__\$ResultVoidAndErrors\$Fields payload;\} __swift_bridge__\$ResultVoidAndErrors;\n?"
)

matches = list(block_re.finditer(content))
if len(matches) < 2:
    print(f"  {path}: expected duplicate blocks, found {len(matches)} - "
          f"upstream may have changed, please re-check manually", file=sys.stderr)
    sys.exit(1)

print(f"  {path}: found {len(matches)} copies, keeping first, removing {len(matches)-1} duplicate(s)")

def repl(m, counter=[0]):
    counter[0] += 1
    return m.group(0) if counter[0] == 1 else ""

patched = block_re.sub(repl, content)
with open(path, "w") as fh:
    fh.write(patched)
PYEOF
done

echo "==> Verifying patched headers compile clean (gcc -fsyntax-only)"
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  hdir="$WORK_DIR/MinimuxerPackage/RustXcframework.xcframework/$slice/Headers"
  cat "$hdir/SwiftBridgeCore.h" "$hdir/minimuxer.h" > "$WORK_DIR/combined-$slice.h"
  if command -v clang >/dev/null 2>&1; then
    CC=clang
  else
    CC=gcc
  fi
  if "$CC" -fsyntax-only -fdollars-in-identifiers "$WORK_DIR/combined-$slice.h" 2> "$WORK_DIR/err-$slice.log"; then
    echo "  $slice: OK, no redefinition errors"
  else
    echo "  $slice: STILL FAILING - see below"
    cat "$WORK_DIR/err-$slice.log"
    exit 1
  fi
done

echo "==> Patching missing 'Error' conformance on MinimuxerError enum"
# Bug thứ 2 (khác bug header ở trên): swift-bridge generate ra
# `public enum MinimuxerError { ... }` KHÔNG conform protocol Error, nhưng
# cũng chính bản generate đó lại `throw val.payload.err.intoSwiftRepr()`
# (trả về MinimuxerError) ở khắp nơi trong SwiftBridgeCore.swift/minimuxer.swift.
# Swift bắt buộc kiểu được throw phải conform Error -> "thrown expression type
# 'MinimuxerError' does not conform to 'Error'". Vá tối thiểu: thêm ": Error"
# vào khai báo enum.
swift_file="$WORK_DIR/MinimuxerPackage/Sources/Minimuxer/minimuxer.swift"
if grep -q "^public enum MinimuxerError {$" "$swift_file"; then
  sed -i.bak 's/^public enum MinimuxerError {$/public enum MinimuxerError: Error {/' "$swift_file"
  rm -f "$swift_file.bak"
  echo "  minimuxer.swift: added 'Error' conformance to MinimuxerError"
elif grep -q "^public enum MinimuxerError: Error {$" "$swift_file"; then
  echo "  minimuxer.swift: MinimuxerError already conforms to Error, nothing to do"
else
  echo "  WARNING: could not find expected 'public enum MinimuxerError {' line in $swift_file" \
       "- upstream may have changed, please check manually" >&2
fi

echo "==> Laying out local SPM package at: $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$WORK_DIR/MinimuxerPackage/RustXcframework.xcframework" "$OUT_DIR/"
cp -R "$WORK_DIR/MinimuxerPackage/Sources" "$OUT_DIR/"
cat > "$OUT_DIR/Package.swift" << 'PKGEOF'
// swift-tools-version:5.5.0
// Vendored + patched copy of SideStore/MinimuxerPackage@7a73cc7.
// The upstream minimuxer.h shipped in that revision defines
// __swift_bridge__$ResultVoidAndErrors five times in one header (a swift-bridge
// codegen bug: it re-emits the full type per Rust source file that returns
// Result<(), Errors> instead of once). That's not valid C and fails to compile
// under any Xcode/toolchain. This local copy has the duplicate typedefs
// stripped (keeping only the first definition); the .a static libraries are
// untouched, since only the C header text was wrong, not the compiled Rust code.
import PackageDescription
let package = Package(
    name: "Minimuxer",
    products: [
        .library(name: "Minimuxer", targets: ["Minimuxer"]),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "MMRustXcframework",
            path: "RustXcframework.xcframework"
        ),
        .target(
            name: "Minimuxer",
            dependencies: ["MMRustXcframework"]
        ),
    ]
)
PKGEOF

echo "==> Done. Vendored + patched package is at: $OUT_DIR"
echo "    Next: point your root Package.swift at it with .package(path: \"$OUT_DIR\")"
echo "    (see instructions printed by the assistant for the exact diff)"
