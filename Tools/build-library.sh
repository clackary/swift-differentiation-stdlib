#!/usr/bin/env bash

set -euo pipefail

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

MODULE_NAME="_Differentiation"
ORIGINAL_TARGET_NAME="swift_Differentiation"
BUNDLE_IDENTIFIER="com.differentiable-swift.differentiation"
BUNDLE_NAME="Differentiation"
ORIGINAL_LIBRARY_BASENAME="lib${ORIGINAL_TARGET_NAME}.dylib"

# build_id | output_id | sysroot | deployment | target | CFBundleSupportedPlatforms | layout
SLICES=(
  "macosx|macos-arm64|macosx|26.0|arm64-apple-macos26.0|MacOSX|versioned"
  "iphoneos|ios-arm64|iphoneos|26.0|arm64-apple-ios26.0|iPhoneOS|flat"
  "iphonesimulator|ios-arm64-simulator|iphonesimulator|26.0|arm64-apple-ios26.0-simulator|iPhoneSimulator|flat"
)

# ----------------------------------------------------------------------------
# Mutable state
# ----------------------------------------------------------------------------

swift_source=""
output_path=""
keep_work_dir=0
toolchain_path=""
swiftc_bin=""
swift_resource_dir=""
bundle_version=""
work_dir=""
stage_dir=""
build_root=""
module_cache=""
vendor_dir=""
slice_staging=""
staging_output=""
staged_differentiation_dir=""
staged_cmake_lists=""

# ----------------------------------------------------------------------------
# Diagnostics and small utilities
# ----------------------------------------------------------------------------

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

warn() {
  echo "warning: $*" >&2
}

usage() {
  cat <<EOF
Usage:
  Tools/build-library.sh --swift-source PATH --toolchain PATH [--output PATH]

Builds an ${MODULE_NAME} XCFramework from a swiftlang/swift source tree and
verifies it. Writes the result to --output. See Tools/release.sh for publishing
as a release asset.

Both arguments are required as paths so that the compatibility is explicit,
rather than an accident of whatever swiftc was on PATH.

Slices are dynamic libraries packaged as .framework bundles, each with a dSYM.

Options:
  --swift-source PATH  swiftlang/swift checkout to build the sources from.
  --toolchain PATH     swift.org .xctoolchain to build with, e.g.
                       ~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain.
  --output PATH        Where to write the XCFramework. Defaults to
                       <work dir>/${MODULE_NAME}.xcframework, which is deleted on
                       exit unless --keep-work-dir is given.
  --keep-work-dir      Keep the temporary staging/build directory.
  -h, --help           Show this help.

Framework slices are built with debug info and shipped with a dSYM, referenced
by a DebugSymbolsPath key in each xcframework entry. Without one, App Store
Connect warns that the archive is missing a dSYM and crash reports from the
library never symbolicate.

Framework bundles are stamped with CFBundleIdentifier ${BUNDLE_IDENTIFIER}
and CFBundleName ${BUNDLE_NAME}; edit the constants at the top of this script to
change them. CFBundleVersion comes from the toolchain the build ran with.
EOF
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

slice_field() {
  local spec="$1" index="$2"
  local IFS='|'
  local -a parts
  read -r -a parts <<<"$spec"
  printf '%s' "${parts[$index]-}"
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

parse_arguments() {
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
      --toolchain)
        [[ $# -ge 2 ]] || die "--toolchain requires a path to an .xctoolchain"
        toolchain_path="$2"
        shift 2
        ;;
      --toolchain=*)
        toolchain_path="${1#*=}"
        shift
        ;;
      --output)
        [[ $# -ge 2 ]] || die "--output requires a path"
        output_path="$2"
        shift 2
        ;;
      --output=*)
        output_path="${1#*=}"
        shift
        ;;
      --keep-work-dir)
        keep_work_dir=1
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
  [[ -n "$toolchain_path" ]] || die "--toolchain is required"
}

require_tools() {
  require_tool cmake
  require_tool ninja
  require_tool xcrun
  require_tool xcodebuild
  require_tool install_name_tool
  require_tool otool
  require_tool plutil
  require_tool dsymutil
}

# Pins the compiler for the whole run and reads its standard library location.
resolve_toolchain() {
  local toolchain_usr

  toolchain_usr="$(absolute_existing_dir "${toolchain_path}/usr")"
  swiftc_bin="${toolchain_usr}/bin/swiftc"
  [[ -x "$swiftc_bin" ]] || die "no swiftc in ${toolchain_path}"

  swift_resource_dir="$("$swiftc_bin" -print-target-info \
    | grep -o '"runtimeResourcePath": *"[^"]*"' | cut -d'"' -f4)"

  [[ -d "$swift_resource_dir" ]] \
    || die "runtimeResourcePath does not name a directory: ${swift_resource_dir}"

  log "Compiler:  ${swiftc_bin}"
  log "Version:   $("$swiftc_bin" -version 2>/dev/null | head -1)"
  log "Stdlib:    ${swift_resource_dir}"
}

resolve_swift_source() {
  swift_source="$(absolute_existing_dir "$swift_source")"

  [[ -f "${swift_source}/Runtimes/Resync.cmake" ]] || die "missing Runtimes/Resync.cmake under ${swift_source}"
  [[ -d "${swift_source}/Runtimes/Supplemental/Differentiation" ]] || die "missing Runtimes/Supplemental/Differentiation under ${swift_source}"
  [[ -d "${swift_source}/stdlib/public/Differentiation" ]] || die "missing stdlib/public/Differentiation under ${swift_source}"
  [[ -x "${swift_source}/utils/gyb" ]] || die "missing executable utils/gyb under ${swift_source}"
}

cleanup() {
  if [[ "$keep_work_dir" -eq 1 ]]; then
    log "Kept work directory: ${work_dir}"
  else
    rm -rf "$work_dir"
  fi
}

create_work_dir() {
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/swift-differentiation-stdlib.XXXXXX")"
  trap cleanup EXIT

  stage_dir="${work_dir}/swift-stage"
  build_root="${work_dir}/build"
  module_cache="${work_dir}/module-cache"
  vendor_dir="${work_dir}/vendor"
  slice_staging="${work_dir}/slices"
  staging_output="${work_dir}/${MODULE_NAME}.xcframework"
  staged_differentiation_dir="${stage_dir}/Runtimes/Supplemental/Differentiation"
  staged_cmake_lists="${staged_differentiation_dir}/CMakeLists.txt"

  export CLANG_MODULE_CACHE_PATH="$module_cache"
}

stage_sources() {
  log "Staging swift Runtimes under ${stage_dir}"
  mkdir -p "$stage_dir" "$build_root" "$module_cache" "$slice_staging"
  cp -R "${swift_source}/Runtimes" "${stage_dir}/Runtimes"
  ln -s "${swift_source}/stdlib" "${stage_dir}/stdlib"

  log "Resyncing staged runtime sources"
  cmake -P "${stage_dir}/Runtimes/Resync.cmake"
}

# Check for vendor cmake hook from upstream sources
require_vendor_hooks() {
  local cmake_lists="$1" hook

  for hook in Settings swift_Differentiation; do
    grep -q "VENDOR_MODULE_DIR}/${hook}.cmake" "$cmake_lists" \
      || die "${cmake_lists} no longer includes the ${hook}.cmake vendor hook; upstream changed its extension points"
  done
}

# Runtimes/Supplemental/Differentiation/CMakeLists.txt offers two vendor hooks,
# and this writes a file for each. Nothing in the swift checkout is modified.
#
#   Settings.cmake              included early, after ResourceEmbedding has
#                               defined generate_plist() but before it is
#                               called, so redefining it there suppresses it.
#
#   swift_Differentiation.cmake included as the last line of the file, after
#                               add_library, so the target exists and
#                               target_compile_options can be set on it.
write_vendor_module() {
  mkdir -p "$vendor_dir"

  # -module-link-name sets the autolink directive consumers get.
  # ScanningLoaders.cpp reads it for the *name* and isFramework for the *kind*,
  # so a framework wants -module-link-name _Differentiation, which autolinks
  # `-framework _Differentiation` and matches _Differentiation.framework.
  #
  # Overriding is required, not optional. Runtimes/Core/cmake/modules/CMakeWorkarounds.cmake
  # hardcodes `-module-link-name <SWIFT_LIBRARY_NAME>` into
  # CMAKE_Swift_CREATE_*_LIBRARY, so every build already passes
  # -module-link-name swift_Differentiation. Simply not injecting leaves that
  # value in place (and would autolink `-framework swift_Differentiation`); the
  # injected option lands later in <FLAGS> and wins. verify_module_dir checks
  # the generated interface for the result.
  cat > "${vendor_dir}/swift_Differentiation.cmake" <<CMAKE
# Generated by Tools/build-library.sh -- do not edit by hand.
target_compile_options(${ORIGINAL_TARGET_NAME} PRIVATE
  "\$<\$<COMPILE_LANGUAGE:Swift>:SHELL:-module-link-name ${MODULE_NAME}>")
target_compile_options(${ORIGINAL_TARGET_NAME} PRIVATE
  "\$<\$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -empty-abi-descriptor>")
CMAKE

  cat > "${vendor_dir}/Settings.cmake" <<'CMAKE'
# Generated by Tools/build-library.sh -- do not edit by hand.
#
# Suppresses upstream's generate_plist(). It links an __TEXT,__info_plist
# section into the dylib via -sectcreate, and iOS rejects a bundled executable
# carrying that section (ITMS-90079: "The application executable contains an
# embedded __INFO_PLIST section, which is not allowed for iOS applications").
# Packaged as a framework, identity comes from the bundle's Info.plist file
# instead, which is also what codesign reads when signing a bundle.
#
# ResourceEmbedding has already been included by the time this file runs, so
# redefining the function replaces it for the generate_plist() call later in the
# project. The only thing lost is the plist: upstream's -application_extension
# branch appends to a local `link_flags` variable that is never used.
function(generate_plist project_name project_version target)
endfunction()
CMAKE
}

# ----------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------

build_slice() {
  local identifier="$1"
  local sysroot="$2"
  local deployment_target="$3"
  local compiler_target="$4"
  local build_dir="${build_root}/${identifier}"
  local -a extra_args=()
  local stdlib_dir="${swift_resource_dir}/${sysroot}"
  local swift_flags=""

  # Compile against the toolchain's standard library rather than the SDK's.
  [[ -d "${stdlib_dir}/Swift.swiftmodule" ]] \
    || die "no standard library for ${sysroot} under ${swift_resource_dir}; use a swift.org toolchain"
  swift_flags="-I ${stdlib_dir}"

  # Debug info, so each slice can carry a dSYM and crash reports from the
  # library symbolicate. CMAKE_<LANG>_FLAGS is prepended to the per-config
  # flags, so this adds -g without discarding the Release optimisation
  # settings.
  swift_flags="${swift_flags} -g"
  extra_args+=(-DCMAKE_C_FLAGS=-g)

  extra_args+=("-DCMAKE_Swift_FLAGS=${swift_flags}")

  log "Configuring ${identifier}"
  cmake -G Ninja \
    -B "$build_dir" \
    -S "$staged_differentiation_dir" \
    -DCMAKE_Swift_COMPILER="$swiftc_bin" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=YES \
    -DCMAKE_C_COMPILER_TARGET="$compiler_target" \
    -DCMAKE_CXX_COMPILER_TARGET="$compiler_target" \
    -DCMAKE_Swift_COMPILER_TARGET="$compiler_target" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSwiftDifferentiation_SWIFTC_SOURCE_DIR="$swift_source" \
    -DSwiftDifferentiation_ENABLE_LIBRARY_EVOLUTION=YES \
    -DSwiftDifferentiation_ENABLE_VECTOR_TYPES=YES \
    -DSwiftDifferentiation_VENDOR_MODULE_DIR="$vendor_dir" \
    ${extra_args[@]+"${extra_args[@]}"}

  log "Building ${identifier}"
  cmake --build "$build_dir"
}

# ----------------------------------------------------------------------------
# Bundle version
# ----------------------------------------------------------------------------

# CFBundleVersion for the framework bundles.
#
# Previously recovered by grepping a generated .swiftinterface, which needed an
# environment override for when the derivation went wrong. The toolchain is now
# an explicit input, so ask the compiler instead. CFBundleVersion wants up to
# three integers, so a snapshot's `6.4.x` becomes `6.4.0`.
resolve_bundle_version() {
  local reported

  reported="$("$swiftc_bin" -version 2>/dev/null \
    | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)"

  [[ -n "$reported" ]] \
    || die "could not read a version from '${swiftc_bin} -version'"

  case "$reported" in
    *.*.*) bundle_version="$reported" ;;
    *.*)   bundle_version="${reported}.0" ;;
    *)     bundle_version="${reported}.0.0" ;;
  esac

  log "Stamping CFBundleVersion ${bundle_version}"
}

# ----------------------------------------------------------------------------
# Packaging
# ----------------------------------------------------------------------------

write_framework_info_plist() {
  local destination="$1" cf_platform="$2" min_os="$3" version="$4"
  local min_os_key="MinimumOSVersion"

  if [[ "$cf_platform" == "MacOSX" ]]; then
    min_os_key="LSMinimumSystemVersion"
  fi

  cat > "$destination" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${MODULE_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_IDENTIFIER}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${BUNDLE_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>${cf_platform}</string>
	</array>
	<key>${min_os_key}</key>
	<string>${min_os}</string>
</dict>
</plist>
PLIST

  plutil -lint "$destination" >/dev/null \
    || die "generated framework Info.plist is malformed: ${destination}"
}

package_framework_slice() {
  local build_dir="$1" slice_dir="$2" cf_platform="$3" min_os="$4" layout="$5"
  local built_library="${build_dir}/${ORIGINAL_LIBRARY_BASENAME}"
  local built_module_dir="${build_dir}/${MODULE_NAME}.swiftmodule"
  local framework_dir="${slice_dir}/${MODULE_NAME}.framework"
  local binary_dir="$framework_dir"
  local resources_dir="$framework_dir"
  local modules_dir="${framework_dir}/Modules"
  local install_name="@rpath/${MODULE_NAME}.framework/${MODULE_NAME}"

  [[ -f "$built_library" ]] || die "missing built library: ${built_library}"
  [[ -d "$built_module_dir" ]] || die "missing built Swift module directory: ${built_module_dir}"

  if [[ "$layout" == "versioned" ]]; then
    binary_dir="${framework_dir}/Versions/A"
    resources_dir="${framework_dir}/Versions/A/Resources"
    modules_dir="${framework_dir}/Versions/A/Modules"
    install_name="@rpath/${MODULE_NAME}.framework/Versions/A/${MODULE_NAME}"
  fi

  mkdir -p "$binary_dir" "$resources_dir" "$modules_dir"
  cp "$built_library" "${binary_dir}/${MODULE_NAME}"
  install_name_tool -id "$install_name" "${binary_dir}/${MODULE_NAME}"
  cp -R "$built_module_dir" "${modules_dir}/${MODULE_NAME}.swiftmodule"
  find "${modules_dir}/${MODULE_NAME}.swiftmodule" -name '*.swiftsourceinfo' -delete
  write_framework_info_plist "${resources_dir}/Info.plist" "$cf_platform" "$min_os" "$bundle_version"

  if [[ "$layout" == "versioned" ]]; then
    ( cd "${framework_dir}/Versions" && ln -sfn A Current )
    ( cd "$framework_dir" \
      && ln -sfn "Versions/Current/${MODULE_NAME}" "$MODULE_NAME" \
      && ln -sfn Versions/Current/Resources Resources \
      && ln -sfn Versions/Current/Modules Modules )
  fi

  # Without a dSYM, App Store Connect reports "The archive did not include a
  # dSYM for _Differentiation.framework" and crash reports from the library
  # never symbolicate. Extracted before signing, since dsymutil reads the
  # unsigned binary.
  mkdir -p "${slice_dir}/dSYMs"
  dsymutil "${binary_dir}/${MODULE_NAME}" \
    -o "${slice_dir}/dSYMs/${MODULE_NAME}.framework.dSYM" >/dev/null \
    || die "dsymutil failed for ${slice_dir}"
}

copy_slice() {
  local spec="$1"
  local build_identifier output_identifier cf_platform deployment layout
  build_identifier="$(slice_field "$spec" 0)"
  output_identifier="$(slice_field "$spec" 1)"
  deployment="$(slice_field "$spec" 3)"
  cf_platform="$(slice_field "$spec" 5)"
  layout="$(slice_field "$spec" 6)"

  local build_dir="${build_root}/${build_identifier}"
  local slice_dir="${slice_staging}/${output_identifier}"

  mkdir -p "$slice_dir"
  package_framework_slice "$build_dir" "$slice_dir" "$cf_platform" "$deployment" "$layout"
}

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------

verify_module_dir() {
  local module_dir="$1"
  local found_swiftdoc=0
  local interface producer

  [[ -d "$module_dir" ]] || die "missing Swift module directory: ${module_dir}"

  local -a interfaces=()
  while IFS= read -r -d '' interface; do
    interfaces+=("$interface")
  done < <(find "$module_dir" -name '*.swiftinterface' -print0)
  [[ "${#interfaces[@]}" -gt 0 ]] || die "no textual Swift interfaces found in ${module_dir}"

  for interface in "${interfaces[@]}"; do
    if ! grep -q -- "-module-link-name ${MODULE_NAME}" "$interface"; then
      die "${interface} does not contain -module-link-name ${MODULE_NAME}"
    fi
    if grep -q -- "-module-link-name ${ORIGINAL_TARGET_NAME}" "$interface"; then
      die "${interface} still contains -module-link-name ${ORIGINAL_TARGET_NAME}; the override did not take effect"
    fi
  done

  while IFS= read -r -d '' _; do
    found_swiftdoc=1
  done < <(find "$module_dir" -name '*.swiftdoc' -print0)
  [[ "$found_swiftdoc" -eq 1 ]] || die "no Swift documentation modules found in ${module_dir}"

  # One artifact serves both SwiftPM and Xcode consumers, and it has to be the
  # swift.org-built one: Xcode's compiler can rebuild these declarations from the
  # generated .swiftinterface, but not the reverse. An Xcode toolchain reports a
  # swiftlang- build number; seeing one here means the wrong --toolchain was
  # passed and the artifact would only load for Xcode users.
  producer="$(awk '
    /^\/\/ swift-compiler-version: / {
      sub(/^\/\/ swift-compiler-version: /, "")
      print
      exit
    }' "${interfaces[0]}")"
  case "$producer" in
    "") warn "no swift-compiler-version recorded in ${module_dir}" ;;
    *swiftlang-*) die "module built by '${producer}', an Xcode toolchain; pass a swift.org --toolchain" ;;
    *) : ;;
  esac
}

verify_framework_slice() {
  local slice_dir="$1" layout="$2"
  local framework_dir="${slice_dir}/${MODULE_NAME}.framework"
  local binary="${framework_dir}/${MODULE_NAME}"
  local real_binary="$binary"
  local info_plist="${framework_dir}/Info.plist"
  local expected_install_name="@rpath/${MODULE_NAME}.framework/${MODULE_NAME}"

  [[ -d "$framework_dir" ]] || die "missing framework bundle: ${framework_dir}"

  if [[ "$layout" == "versioned" ]]; then
    real_binary="${framework_dir}/Versions/A/${MODULE_NAME}"
    info_plist="${framework_dir}/Versions/A/Resources/Info.plist"
    expected_install_name="@rpath/${MODULE_NAME}.framework/Versions/A/${MODULE_NAME}"
    [[ -L "${framework_dir}/Versions/Current" ]] || die "missing Versions/Current symlink in ${framework_dir}"
    [[ -L "$binary" ]] || die "missing top-level ${MODULE_NAME} symlink in ${framework_dir}"
    [[ -L "${framework_dir}/Resources" ]] || die "missing top-level Resources symlink in ${framework_dir}"
    [[ -L "${framework_dir}/Modules" ]] || die "missing top-level Modules symlink in ${framework_dir}"
  fi

  [[ -f "$real_binary" ]] || die "missing framework executable: ${real_binary}"
  [[ -f "$info_plist" ]] || die "missing framework Info.plist: ${info_plist}"
  plutil -lint "$info_plist" >/dev/null || die "malformed framework Info.plist: ${info_plist}"

  if ! otool -D "$real_binary" | grep -q -- "$expected_install_name"; then
    die "${real_binary} does not have ${expected_install_name} as its install name"
  fi

  # iOS rejects a bundled executable carrying __TEXT,__info_plist (ITMS-90079),
  # so the vendor Settings.cmake must have suppressed generate_plist().
  if otool -P "$real_binary" | grep -q -- "<?xml"; then
    die "${real_binary} carries an embedded __info_plist; iOS rejects that with ITMS-90079"
  fi

  local dsym="${slice_dir}/dSYMs/${MODULE_NAME}.framework.dSYM"
  [[ -d "$dsym" ]] || die "missing dSYM: ${dsym}"
  [[ -f "${dsym}/Contents/Resources/DWARF/${MODULE_NAME}" ]] \
    || die "dSYM has no DWARF binary: ${dsym}"

  verify_module_dir "${framework_dir}/Modules/${MODULE_NAME}.swiftmodule"
}

# Compiles a probe against the packaged slice.
#
# Grepping the textual interface cannot catch a module that fails to
# deserialize: 604.0.0-prerelease-3 passed every interface check here and still
# could not be imported by the compiler that produced it. Conformances are
# validated on demand, so `import _Differentiation` alone does not surface it --
# the probe has to touch one.
verify_module_imports() {
  local slice_dir="$1" sysroot="$2" compiler_target="$3"
  local probe="${work_dir}/probe-${compiler_target}.swift"
  local object="${work_dir}/probe-${compiler_target}.o"
  local sdk_path
  local -a search_flags=()

  sdk_path="$(xcrun --sdk "$sysroot" --show-sdk-path 2>/dev/null)" \
    || die "could not resolve an SDK path for sysroot ${sysroot}"

  cat > "$probe" <<'SWIFT'
import _Differentiation

@inline(never)
func _probeAdditiveArithmetic() -> Array<Double>.DifferentiableView {
  Array<Double>.DifferentiableView.zero
}

@inline(never)
func _probeDifferentiable(_ value: [Double]) -> Array<Double>.DifferentiableView {
  Array<Double>.DifferentiableView(value)
}
SWIFT

  search_flags=(-F "$slice_dir")

  "$swiftc_bin" -c -O \
    -target "$compiler_target" \
    -sdk "$sdk_path" \
    "${search_flags[@]}" \
    "$probe" -o "$object" \
    || die "the packaged module in ${slice_dir} cannot be imported; see the compiler error above"
}

verify_slice() {
  local spec="$1"
  local output_identifier layout slice_dir sysroot compiler_target
  output_identifier="$(slice_field "$spec" 1)"
  sysroot="$(slice_field "$spec" 2)"
  compiler_target="$(slice_field "$spec" 4)"
  layout="$(slice_field "$spec" 6)"
  slice_dir="${staging_output}/${output_identifier}"

  log "Verifying ${output_identifier}"

  verify_framework_slice "$slice_dir" "$layout"

  verify_module_imports "$slice_dir" "$sysroot" "$compiler_target"
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

# Assembles the packaged slices into the xcframework.
#
# xcodebuild writes the top-level Info.plist itself, deriving SupportedPlatform,
# SupportedPlatformVariant and SupportedArchitectures from each binary's Mach-O
# load commands, and adding DebugSymbolsPath for every -debug-symbols given.
create_xcframework() {
  local spec output_identifier slice_dir
  local -a args=()

  for spec in "${SLICES[@]}"; do
    output_identifier="$(slice_field "$spec" 1)"
    slice_dir="${slice_staging}/${output_identifier}"

    args+=(-framework "${slice_dir}/${MODULE_NAME}.framework")
    # -debug-symbols rejects a relative path; work_dir is absolute.
    args+=(-debug-symbols "${slice_dir}/dSYMs/${MODULE_NAME}.framework.dSYM")
  done

  # The output must not already exist, which is why nothing creates it earlier.
  xcodebuild -create-xcframework "${args[@]}" -output "$staging_output" \
    || die "xcodebuild -create-xcframework failed"

  plutil -lint "${staging_output}/Info.plist" >/dev/null \
    || die "xcodebuild wrote a malformed Info.plist into ${staging_output}"
}

install_output() {
  if [[ -z "$output_path" ]]; then
    keep_work_dir=1
    log "Built ${staging_output}"
    return
  fi

  log "Writing ${output_path}"
  rm -rf "${output_path}.previous"
  if [[ -e "$output_path" ]]; then
    mv "$output_path" "${output_path}.previous"
  fi
  if mv "$staging_output" "$output_path"; then
    rm -rf "${output_path}.previous"
  else
    if [[ -e "${output_path}.previous" ]]; then
      mv "${output_path}.previous" "$output_path"
    fi
    die "failed to move ${staging_output} into place"
  fi

  log "Built ${output_path}"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  local spec

  parse_arguments "$@"
  require_tools

  resolve_toolchain
  resolve_swift_source
  resolve_bundle_version

  create_work_dir
  stage_sources

  require_vendor_hooks "$staged_cmake_lists"

  log "Writing vendor modules for the link name and the embedded __info_plist"
  write_vendor_module

  log "Building slices in ${slice_staging}"
  for spec in "${SLICES[@]}"; do
    build_slice \
      "$(slice_field "$spec" 0)" \
      "$(slice_field "$spec" 2)" \
      "$(slice_field "$spec" 3)" \
      "$(slice_field "$spec" 4)"
    copy_slice "$spec"
  done

  log "Assembling the xcframework in ${staging_output}"
  create_xcframework

  for spec in "${SLICES[@]}"; do
    verify_slice "$spec"
  done

  install_output
}

main "$@"
