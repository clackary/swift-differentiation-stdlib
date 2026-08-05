#!/usr/bin/env bash

set -euo pipefail

MODULE_NAME="_Differentiation"
ORIGINAL_TARGET_NAME="swift_Differentiation"
MODULE_LINK_NAME="lib_Differentiation"
shared_library=0

usage() {
  cat <<EOF
Usage:
  Tools/build-library.sh --swift-source PATH [--shared-library] [--keep-work-dir]

Builds a static ${MODULE_NAME} XCFramework from a swiftlang/swift source tree by
default. Pass --shared-library to build a dynamic XCFramework instead.
Replaces ${MODULE_NAME}.xcframework at the repository root.

Options:
  --swift-source PATH  Path to the swiftlang/swift checkout.
  --shared-library     Build a shared library (.dylib) instead of a static one (.a).
  --keep-work-dir      Keep the temporary staging/build directory for inspection.
  -h, --help           Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' was not found on PATH"
}

absolute_existing_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "directory does not exist: $path"
  cd "$path" >/dev/null
  pwd -P
}

absolute_output_path() {
  local path="$1"
  local parent
  local base
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  mkdir -p "$parent"
  cd "$parent" >/dev/null
  printf '%s/%s\n' "$(pwd -P)" "$base"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd -P)"
swift_source=""
output_path="${repo_root}/${MODULE_NAME}.xcframework"
keep_work_dir=0
library_extension="a"
build_shared_libs="NO"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --swift-source)
      [[ $# -ge 2 ]] || die "--swift-source requires a path"
      swift_source="$2"
      shift 2
      ;;
    --swift-source=*)
      swift_source="${1#*=}"
      shift
      ;;
    --keep-work-dir)
      keep_work_dir=1
      shift
      ;;
    --shared-library)
      shared_library=1
      library_extension="dylib"
      build_shared_libs="YES"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$swift_source" ]] || die "--swift-source is required"

require_tool cmake
require_tool ninja
if [[ "$shared_library" -eq 1 ]]; then
  require_tool install_name_tool
fi

ORIGINAL_LIBRARY_BASENAME="lib${ORIGINAL_TARGET_NAME}.${library_extension}"
# Swift turns -module-link-name lib_Differentiation into -llib_Differentiation,
# so the packaged library must carry the Darwin lib prefix as liblib_Differentiation.
LIBRARY_BASENAME="lib${MODULE_LINK_NAME}.${library_extension}"

swift_source="$(absolute_existing_dir "$swift_source")"

[[ -f "${swift_source}/Runtimes/Resync.cmake" ]] || die "missing Runtimes/Resync.cmake under ${swift_source}"
[[ -d "${swift_source}/Runtimes/Supplemental/Differentiation" ]] || die "missing Runtimes/Supplemental/Differentiation under ${swift_source}"
[[ -d "${swift_source}/stdlib/public/Differentiation" ]] || die "missing stdlib/public/Differentiation under ${swift_source}"
[[ -x "${swift_source}/utils/gyb" ]] || die "missing executable utils/gyb under ${swift_source}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/swift-differentiation-stdlib.XXXXXX")"
cleanup() {
  if [[ "$keep_work_dir" -eq 1 ]]; then
    log "Kept work directory: ${work_dir}"
  else
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

stage_dir="${work_dir}/swift-stage"
build_root="${work_dir}/build"
module_cache="${work_dir}/module-cache"
staged_differentiation_dir="${stage_dir}/Runtimes/Supplemental/Differentiation"
staged_cmake_lists="${staged_differentiation_dir}/CMakeLists.txt"

log "Staging swift Runtimes under ${stage_dir}"
mkdir -p "$stage_dir" "$build_root" "$module_cache"
cp -R "${swift_source}/Runtimes" "${stage_dir}/Runtimes"
ln -s "${swift_source}/stdlib" "${stage_dir}/stdlib"

log "Resyncing staged runtime sources"
cmake -P "${stage_dir}/Runtimes/Resync.cmake"

patch_cmake_lists() {
  local input="$1"
  local tmp="${input}.tmp"

  awk -v module_link_name="$MODULE_LINK_NAME" '
    {
      print
      if ($0 ~ /^  Swift_MODULE_NAME _Differentiation\)$/) {
        print ""
        print "target_compile_options(swift_Differentiation PRIVATE"
        print "  \"\$<\$<COMPILE_LANGUAGE:Swift>:SHELL:-module-link-name " module_link_name ">\")"
        print "target_compile_options(swift_Differentiation PRIVATE"
        print "  \"\$<\$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -empty-abi-descriptor>\")"
      }
    }
  ' "$input" > "$tmp"

  if ! grep -q -- "-module-link-name ${MODULE_LINK_NAME}" "$tmp"; then
    rm -f "$tmp"
    die "failed to patch ${input} with module link name ${MODULE_LINK_NAME}"
  fi
  if ! grep -q -- "-empty-abi-descriptor" "$tmp"; then
    rm -f "$tmp"
    die "failed to patch ${input} with -empty-abi-descriptor"
  fi

  mv "$tmp" "$input"
}

log "Patching staged CMake to emit -module-link-name ${MODULE_LINK_NAME}"
patch_cmake_lists "$staged_cmake_lists"

export CLANG_MODULE_CACHE_PATH="$module_cache"

build_slice() {
  local identifier="$1"
  local sysroot="$2"
  local deployment_target="$3"
  local compiler_target="$4"
  local build_dir="${build_root}/${identifier}"

  log "Configuring ${identifier}"
  cmake -G Ninja \
    -B "$build_dir" \
    -S "$staged_differentiation_dir" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS="$build_shared_libs" \
    -DCMAKE_C_COMPILER_TARGET="$compiler_target" \
    -DCMAKE_CXX_COMPILER_TARGET="$compiler_target" \
    -DCMAKE_Swift_COMPILER_TARGET="$compiler_target" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSwiftDifferentiation_SWIFTC_SOURCE_DIR="$swift_source" \
    -DSwiftDifferentiation_ENABLE_LIBRARY_EVOLUTION=YES \
    -DSwiftDifferentiation_ENABLE_VECTOR_TYPES=YES

  log "Building ${identifier}"
  cmake --build "$build_dir"
}

copy_slice() {
  local build_identifier="$1"
  local output_identifier="$2"
  local build_dir="${build_root}/${build_identifier}"
  local slice_dir="${output_path}/${output_identifier}"
  local built_library="${build_dir}/${ORIGINAL_LIBRARY_BASENAME}"
  local built_module_dir="${build_dir}/${MODULE_NAME}.swiftmodule"
  local packaged_module_dir="${slice_dir}/${MODULE_NAME}.swiftmodule"
  local packaged_library="${slice_dir}/${LIBRARY_BASENAME}"

  [[ -f "$built_library" ]] || die "missing built library: ${built_library}"
  [[ -d "$built_module_dir" ]] || die "missing built Swift module directory: ${built_module_dir}"

  mkdir -p "$slice_dir"
  cp "$built_library" "$packaged_library"
  if [[ "$shared_library" -eq 1 ]]; then
    install_name_tool -id "@rpath/${LIBRARY_BASENAME}" "$packaged_library"
  fi
  cp -R "$built_module_dir" "$packaged_module_dir"

  # Keep compiler-produced binary module artifacts so consumers using the exact
  # same compiler release can import the prebuilt module instead of rechecking
  # the textual interface.
  find "$packaged_module_dir" -name '*.swiftsourceinfo' -delete
}

verify_slice() {
  local identifier="$1"
  local slice_dir="${output_path}/${identifier}"
  local packaged_library="${slice_dir}/${LIBRARY_BASENAME}"
  local found_interface=0
  local found_binary_module=0
  local found_swiftdoc=0

  [[ -f "$packaged_library" ]] || die "missing packaged library: ${packaged_library}"

  if [[ "$shared_library" -eq 1 ]]; then
    if ! otool -D "$packaged_library" | grep -q -- "@rpath/${LIBRARY_BASENAME}"; then
      die "${packaged_library} does not have @rpath/${LIBRARY_BASENAME} as its install name"
    fi
  fi

  while IFS= read -r -d '' interface; do
    found_interface=1
    if ! grep -q -- "-module-link-name ${MODULE_LINK_NAME}" "$interface"; then
      die "${interface} does not contain -module-link-name ${MODULE_LINK_NAME}"
    fi
    if grep -q -- "-module-link-name ${ORIGINAL_TARGET_NAME}" "$interface"; then
      die "${interface} still contains -module-link-name ${ORIGINAL_TARGET_NAME}"
    fi
  done < <(find "${slice_dir}/${MODULE_NAME}.swiftmodule" -name '*.swiftinterface' -print0)

  [[ "$found_interface" -eq 1 ]] || die "no textual Swift interfaces found in ${slice_dir}/${MODULE_NAME}.swiftmodule"
  while IFS= read -r -d '' _; do
    found_binary_module=1
  done < <(find "${slice_dir}/${MODULE_NAME}.swiftmodule" -name '*.swiftmodule' -print0)
  [[ "$found_binary_module" -eq 1 ]] || die "no binary Swift modules found in ${slice_dir}/${MODULE_NAME}.swiftmodule"

  while IFS= read -r -d '' _; do
    found_swiftdoc=1
  done < <(find "${slice_dir}/${MODULE_NAME}.swiftmodule" -name '*.swiftdoc' -print0)
  [[ "$found_swiftdoc" -eq 1 ]] || die "no Swift documentation modules found in ${slice_dir}/${MODULE_NAME}.swiftmodule"
}

write_info_plist() {
  cat > "${output_path}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>${LIBRARY_BASENAME}</string>
			<key>SwiftModulesPath</key>
			<string>${MODULE_NAME}.swiftmodule</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>${LIBRARY_BASENAME}</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>${LIBRARY_BASENAME}</string>
			<key>SwiftModulesPath</key>
			<string>${MODULE_NAME}.swiftmodule</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64-simulator</string>
			<key>LibraryPath</key>
			<string>${LIBRARY_BASENAME}</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>${LIBRARY_BASENAME}</string>
			<key>SwiftModulesPath</key>
			<string>${MODULE_NAME}.swiftmodule</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>${LIBRARY_BASENAME}</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
}

log "Preparing output at ${output_path}"
rm -rf "$output_path"
mkdir -p "$output_path"

build_slice macosx macosx 13.0 arm64-apple-macos13.0
copy_slice macosx macos-arm64

build_slice iphoneos iphoneos 16.0 arm64-apple-ios16.0
copy_slice iphoneos ios-arm64

build_slice iphonesimulator iphonesimulator 16.0 arm64-apple-ios16.0-simulator
copy_slice iphonesimulator ios-arm64-simulator

write_info_plist

verify_slice macos-arm64
verify_slice ios-arm64
verify_slice ios-arm64-simulator

log "Built ${output_path}"
