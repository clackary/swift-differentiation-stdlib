#!/usr/bin/env bash

set -euo pipefail

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

MODULE_NAME="_Differentiation"
ORIGINAL_TARGET_NAME="swift_Differentiation"
MODULE_LINK_NAME="lib_Differentiation"

# The framework bundle name must equal the Swift module name. A module loaded
# from <Name>.framework/Modules/<Name>.swiftmodule autolinks as
# `-framework <module name>` (lib/Serialization/ModuleFile.cpp and
# ScanningLoaders.cpp add a LibraryKind::Framework entry named after the
# module), so anything else fails to resolve at link time.
FRAMEWORK_NAME="${MODULE_NAME}"

# Why dynamic slices are packaged as .framework bundles and not loose .dylib
# files.
#
# A loose Swift .dylib in an app's Frameworks/ directory makes App Store
# validation demand a SwiftSupport/ folder (ITMS-90426). Xcode populates
# SwiftSupport by copying Swift runtime libraries it finds in the toolchain; this
# library is not in the toolchain, so nothing is staged and no folder is written,
# yet validation still requires an entry for it. Nothing can satisfy that, since
# the folder exists for Apple to substitute its own runtime libraries. A
# framework bundle is not a loose runtime library, so it is never asked for.
#
# Two consequences follow from the bundle shape:
#
#   * iOS forbids an embedded __TEXT,__info_plist in a bundled executable
#     (ITMS-90079). Upstream links one in from
#     Runtimes/Supplemental/cmake/modules/ResourceEmbedding.cmake, so
#     generate_plist() is suppressed outright via the vendor Settings.cmake hook.
#     Identity comes from the bundle's Info.plist file instead, which is also
#     what codesign reads when signing a bundle.
#   * The autolink directive has to name the framework; see EFFECTIVE_LINK_NAME.
#
# Note that the identity upstream stamps in -- com.apple.dt.runtime.* -- is not
# itself what triggers any of this. Changing it to a non-Apple identifier was
# tested and made no difference to ITMS-90426; the packaging shape is what
# matters, and for ITMS-90079 what matters is that the section exists at all.
BUNDLE_IDENTIFIER="com.differentiable-swift.differentiation"
BUNDLE_NAME="Differentiation"

# Empty means "read it from the generated module interface"; see
# bundle_version_for. Kept as an override because the value is derived rather
# than fixed, so there needs to be a way to correct a bad derivation.
BUNDLE_VERSION="${DIFFERENTIATION_BUNDLE_VERSION:-}"

# build_id | output_id | platform | variant | sysroot | deployment | target | CFBundleSupportedPlatforms | layout
SLICES=(
  "macosx|macos-arm64|macos||macosx|26.0|arm64-apple-macos26.0|MacOSX|versioned"
  "iphoneos|ios-arm64|ios||iphoneos|26.0|arm64-apple-ios26.0|iPhoneOS|flat"
  "iphonesimulator|ios-arm64-simulator|ios|simulator|iphonesimulator|26.0|arm64-apple-ios26.0-simulator|iPhoneSimulator|flat"
)

# ----------------------------------------------------------------------------
# Mutable state
# ----------------------------------------------------------------------------

# Set by parse_arguments; derived values are filled in by configure_derived_names
# and create_work_dir once the shape and the checkout path are known.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd -P)"
swift_source=""
output_path="${repo_root}/${MODULE_NAME}.xcframework"
keep_work_dir=0

# static | framework
package_shape="static"
library_extension="a"
build_shared_libs="NO"

ORIGINAL_LIBRARY_BASENAME=""
LIBRARY_BASENAME=""
EFFECTIVE_LINK_NAME=""

work_dir=""
stage_dir=""
build_root=""
module_cache=""
vendor_dir=""
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
  Tools/build-library.sh --swift-source PATH [--framework] [--keep-work-dir]

Builds an ${MODULE_NAME} XCFramework from a swiftlang/swift source tree.
Replaces ${MODULE_NAME}.xcframework at the repository root, but only once every
slice has been built and verified.

Packaging shapes:
  (default)     Static libraries (.a). Links into the consumer's binary; nothing
                is embedded, so App Store validation never asks for a
                SwiftSupport entry.
  --framework   Dynamic libraries packaged as .framework bundles, each with a
                dSYM. Use when a consumer needs dynamic linking and has to pass
                App Store validation. Loose .dylib packaging is not offered: it
                is rejected with ITMS-90426 and cannot be made to pass.

Options:
  --swift-source PATH  Path to the swiftlang/swift checkout.
  --framework          Package as .framework slices instead of static ones.
  --keep-work-dir      Keep the temporary staging/build directory.
  -h, --help           Show this help.

Framework slices are built with debug info and shipped with a dSYM, referenced
by a DebugSymbolsPath key in each xcframework entry. Without one, App Store
Connect warns that the archive is missing a dSYM and crash reports from the
library never symbolicate.

Framework bundles are stamped with CFBundleIdentifier ${BUNDLE_IDENTIFIER}
and CFBundleName ${BUNDLE_NAME}; edit the constants at the top of this script to
change them. CFBundleVersion is read from the generated module interface
(env: DIFFERENTIATION_BUNDLE_VERSION to override).
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

is_framework() {
  [[ "$package_shape" == "framework" ]]
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
      --keep-work-dir)
        keep_work_dir=1
        shift
        ;;
      --framework)
        package_shape="framework"
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
}

require_toolchain() {
  require_tool cmake
  require_tool ninja
  if is_framework; then
    require_tool install_name_tool
    require_tool codesign
    require_tool otool
    require_tool plutil
    require_tool dsymutil
  fi
}

resolve_swift_source() {
  swift_source="$(absolute_existing_dir "$swift_source")"

  [[ -f "${swift_source}/Runtimes/Resync.cmake" ]] || die "missing Runtimes/Resync.cmake under ${swift_source}"
  [[ -d "${swift_source}/Runtimes/Supplemental/Differentiation" ]] || die "missing Runtimes/Supplemental/Differentiation under ${swift_source}"
  [[ -d "${swift_source}/stdlib/public/Differentiation" ]] || die "missing stdlib/public/Differentiation under ${swift_source}"
  [[ -x "${swift_source}/utils/gyb" ]] || die "missing executable utils/gyb under ${swift_source}"
}

# The link name recorded in the module, which determines the autolink directive
# consumers get. ScanningLoaders.cpp reads -module-link-name for the *name* and
# isFramework for the *kind*, so:
#
#   loose library  -module-link-name lib_Differentiation -> -llib_Differentiation,
#                  which is why the packaged file carries the doubled lib prefix.
#   framework      -module-link-name _Differentiation -> -framework _Differentiation,
#                  matching _Differentiation.framework.
#
# Overriding is required, not optional. Runtimes/Core/cmake/modules/CMakeWorkarounds.cmake
# hardcodes `-module-link-name <SWIFT_LIBRARY_NAME>` into CMAKE_Swift_CREATE_*_LIBRARY,
# so every build already passes -module-link-name swift_Differentiation. Simply
# not injecting leaves that value in place (and would autolink
# `-framework swift_Differentiation`); the injected option lands later in <FLAGS>
# and wins.
configure_derived_names() {
  ORIGINAL_LIBRARY_BASENAME="lib${ORIGINAL_TARGET_NAME}.${library_extension}"
  # Static slices autolink as -llib_Differentiation, so the packaged archive has
  # to carry the Darwin lib prefix twice, as liblib_Differentiation.a.
  LIBRARY_BASENAME="lib${MODULE_LINK_NAME}.${library_extension}"

  if is_framework; then
    EFFECTIVE_LINK_NAME="${MODULE_NAME}"
  else
    EFFECTIVE_LINK_NAME="${MODULE_LINK_NAME}"
  fi
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
  # Slices are assembled here and only moved over ${output_path} once every slice
  # has been verified, so a failed run leaves the previous xcframework intact.
  staging_output="${work_dir}/${MODULE_NAME}.xcframework"
  staged_differentiation_dir="${stage_dir}/Runtimes/Supplemental/Differentiation"
  staged_cmake_lists="${staged_differentiation_dir}/CMakeLists.txt"

  export CLANG_MODULE_CACHE_PATH="$module_cache"
}

stage_sources() {
  log "Staging swift Runtimes under ${stage_dir}"
  mkdir -p "$stage_dir" "$build_root" "$module_cache" "$staging_output"
  cp -R "${swift_source}/Runtimes" "${stage_dir}/Runtimes"
  ln -s "${swift_source}/stdlib" "${stage_dir}/stdlib"

  log "Resyncing staged runtime sources"
  cmake -P "${stage_dir}/Runtimes/Resync.cmake"
}

# Injects the compile options upstream does not offer a switch for.
patch_cmake_lists() {
  local input="$1"
  local tmp="${input}.tmp"

  awk -v module_link_name="$EFFECTIVE_LINK_NAME" '
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

  if ! grep -q -- "-module-link-name ${EFFECTIVE_LINK_NAME}" "$tmp"; then
    rm -f "$tmp"
    die "failed to patch ${input} with module link name ${EFFECTIVE_LINK_NAME}"
  fi
  if ! grep -q -- "-empty-abi-descriptor" "$tmp"; then
    rm -f "$tmp"
    die "failed to patch ${input} with -empty-abi-descriptor"
  fi

  mv "$tmp" "$input"
}

# Runtimes/Supplemental/Differentiation/CMakeLists.txt includes
#
#   include("${${PROJECT_NAME}_VENDOR_MODULE_DIR}/Settings.cmake" OPTIONAL)
#
# early on -- after ResourceEmbedding has been included, so generate_plist()
# already exists, but before it is called. Redefining the function there
# suppresses it. Nothing in the swift checkout is modified.
write_vendor_module() {
  mkdir -p "$vendor_dir"

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

  if is_framework; then
    # Debug info, so each slice can carry a dSYM and crash reports from the
    # library symbolicate. CMAKE_<LANG>_FLAGS is prepended to the per-config
    # flags, so this adds -g without discarding the Release optimisation
    # settings. Static slices are linked into the consumer, which produces its
    # own debug info, so they do not need this.
    extra_args+=(-DCMAKE_Swift_FLAGS=-g -DCMAKE_C_FLAGS=-g)
  fi

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
    -DSwiftDifferentiation_ENABLE_VECTOR_TYPES=YES \
    -DSwiftDifferentiation_VENDOR_MODULE_DIR="$vendor_dir" \
    ${extra_args[@]+"${extra_args[@]}"}

  log "Building ${identifier}"
  cmake --build "$build_dir"
}

# ----------------------------------------------------------------------------
# Reading the generated module interface
# ----------------------------------------------------------------------------

collect_interfaces() {
  local module_dir="$1" found
  _INTERFACES=()
  while IFS= read -r -d '' found; do
    _INTERFACES+=("$found")
  done < <(find "$module_dir" -name '*.swiftinterface' -print0)
}

# Reads the Swift version out of a generated interface, e.g.
# "// swift-compiler-version: Apple Swift version 6.3.3 (swiftlang-...)" -> 6.3.3
# awk rather than sed|head: exiting on the first match keeps this a single
# command, so there is no pipeline for pipefail to trip over.
interface_swift_version() {
  collect_interfaces "$1"
  [[ "${#_INTERFACES[@]}" -gt 0 ]] || return 0
  awk '
    /^\/\/ swift-compiler-version: Apple Swift version [0-9]/ {
      match($0, /version [0-9][0-9.]*/)
      print substr($0, RSTART + 8, RLENGTH - 8)
      exit
    }' "${_INTERFACES[0]}"
}

bundle_version_for() {
  local module_dir="$1"
  local version=""
  if [[ -n "$BUNDLE_VERSION" ]]; then
    printf '%s' "$BUNDLE_VERSION"
    return
  fi
  version="$(interface_swift_version "$module_dir")"
  if [[ -z "$version" ]]; then
    warn "could not read a Swift version from ${module_dir}; using 0.0.0 for CFBundleVersion (set DIFFERENTIATION_BUNDLE_VERSION to override)"
    version="0.0.0"
  fi
  printf '%s' "$version"
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
	<string>${FRAMEWORK_NAME}</string>
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
  local framework_dir="${slice_dir}/${FRAMEWORK_NAME}.framework"
  local binary_dir="$framework_dir"
  local resources_dir="$framework_dir"
  local modules_dir="${framework_dir}/Modules"
  local install_name="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
  local version

  [[ -f "$built_library" ]] || die "missing built library: ${built_library}"
  [[ -d "$built_module_dir" ]] || die "missing built Swift module directory: ${built_module_dir}"

  version="$(bundle_version_for "$built_module_dir")"

  if [[ "$layout" == "versioned" ]]; then
    binary_dir="${framework_dir}/Versions/A"
    resources_dir="${framework_dir}/Versions/A/Resources"
    modules_dir="${framework_dir}/Versions/A/Modules"
    install_name="@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
  fi

  mkdir -p "$binary_dir" "$resources_dir" "$modules_dir"
  cp "$built_library" "${binary_dir}/${FRAMEWORK_NAME}"
  install_name_tool -id "$install_name" "${binary_dir}/${FRAMEWORK_NAME}"
  cp -R "$built_module_dir" "${modules_dir}/${MODULE_NAME}.swiftmodule"
  find "${modules_dir}/${MODULE_NAME}.swiftmodule" -name '*.swiftsourceinfo' -delete
  write_framework_info_plist "${resources_dir}/Info.plist" "$cf_platform" "$min_os" "$version"

  if [[ "$layout" == "versioned" ]]; then
    ( cd "${framework_dir}/Versions" && ln -sfn A Current )
    ( cd "$framework_dir" \
      && ln -sfn "Versions/Current/${FRAMEWORK_NAME}" "$FRAMEWORK_NAME" \
      && ln -sfn Versions/Current/Resources Resources \
      && ln -sfn Versions/Current/Modules Modules )
  fi

  # Without a dSYM, App Store Connect reports "The archive did not include a
  # dSYM for _Differentiation.framework" and crash reports from the library
  # never symbolicate. Extracted before signing, since dsymutil reads the
  # unsigned binary.
  mkdir -p "${slice_dir}/dSYMs"
  dsymutil "${binary_dir}/${FRAMEWORK_NAME}" \
    -o "${slice_dir}/dSYMs/${FRAMEWORK_NAME}.framework.dSYM" >/dev/null \
    || die "dsymutil failed for ${slice_dir}"

  # Signs the bundle, which takes identity from the bundle's Info.plist. Must
  # come after every file is in place, since CodeResources hashes them all.
  codesign --force --sign - "$framework_dir"
}

package_static_slice() {
  local build_dir="$1" slice_dir="$2"
  local built_library="${build_dir}/${ORIGINAL_LIBRARY_BASENAME}"
  local built_module_dir="${build_dir}/${MODULE_NAME}.swiftmodule"
  local packaged_module_dir="${slice_dir}/${MODULE_NAME}.swiftmodule"
  local packaged_library="${slice_dir}/${LIBRARY_BASENAME}"

  [[ -f "$built_library" ]] || die "missing built library: ${built_library}"
  [[ -d "$built_module_dir" ]] || die "missing built Swift module directory: ${built_module_dir}"

  mkdir -p "$slice_dir"
  cp "$built_library" "$packaged_library"
  cp -R "$built_module_dir" "$packaged_module_dir"

  # Keep compiler-produced binary module artifacts so consumers using the exact
  # same compiler release can import the prebuilt module instead of rechecking
  # the textual interface.
  find "$packaged_module_dir" -name '*.swiftsourceinfo' -delete
}

copy_slice() {
  local spec="$1"
  local build_identifier output_identifier cf_platform deployment layout
  build_identifier="$(slice_field "$spec" 0)"
  output_identifier="$(slice_field "$spec" 1)"
  deployment="$(slice_field "$spec" 5)"
  cf_platform="$(slice_field "$spec" 7)"
  layout="$(slice_field "$spec" 8)"

  local build_dir="${build_root}/${build_identifier}"
  local slice_dir="${staging_output}/${output_identifier}"

  mkdir -p "$slice_dir"
  if is_framework; then
    package_framework_slice "$build_dir" "$slice_dir" "$cf_platform" "$deployment" "$layout"
  else
    package_static_slice "$build_dir" "$slice_dir"
  fi
}

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------

verify_module_dir() {
  local module_dir="$1"
  local found_swiftdoc=0
  local interface producer

  [[ -d "$module_dir" ]] || die "missing Swift module directory: ${module_dir}"

  collect_interfaces "$module_dir"
  [[ "${#_INTERFACES[@]}" -gt 0 ]] || die "no textual Swift interfaces found in ${module_dir}"

  for interface in "${_INTERFACES[@]}"; do
    # The effective link name must be the one we injected. Upstream's CMake rule
    # always passes -module-link-name swift_Differentiation, so seeing that value
    # here means the override did not land -- consumers would autolink the wrong
    # library (or, in a framework, the wrong framework).
    if ! grep -q -- "-module-link-name ${EFFECTIVE_LINK_NAME}" "$interface"; then
      die "${interface} does not contain -module-link-name ${EFFECTIVE_LINK_NAME}"
    fi
    if grep -q -- "-module-link-name ${ORIGINAL_TARGET_NAME}" "$interface"; then
      die "${interface} still contains -module-link-name ${ORIGINAL_TARGET_NAME}; the override did not take effect"
    fi
    if is_framework && grep -q -- "-module-link-name ${MODULE_LINK_NAME}" "$interface"; then
      die "${interface} carries the loose-library link name ${MODULE_LINK_NAME}; a framework needs ${MODULE_NAME}"
    fi
  done

  while IFS= read -r -d '' _; do
    found_swiftdoc=1
  done < <(find "$module_dir" -name '*.swiftdoc' -print0)
  [[ "$found_swiftdoc" -eq 1 ]] || die "no Swift documentation modules found in ${module_dir}"

  # Warns rather than fails: an interface produced by a non-Xcode toolchain is
  # still usable by that same toolchain, but Xcode cannot load the binary module
  # and its rebuild from the interface may fail outright.
  producer="$(awk '
    /^\/\/ swift-compiler-version: / {
      sub(/^\/\/ swift-compiler-version: /, "")
      print
      exit
    }' "${_INTERFACES[0]}")"
  case "$producer" in
    *swiftlang-*) : ;;
    "") warn "no swift-compiler-version recorded in ${module_dir}" ;;
    *) warn "module built by '${producer}', which is not an Xcode toolchain; Xcode consumers may fail to load it" ;;
  esac
}

verify_framework_slice() {
  local slice_dir="$1" layout="$2"
  local framework_dir="${slice_dir}/${FRAMEWORK_NAME}.framework"
  # The path the bundle advertises, and the path the Mach-O actually lives at --
  # identical for a flat bundle, different for a versioned one. Inspect the real
  # file rather than the symlink so the checks are unambiguous.
  local binary="${framework_dir}/${FRAMEWORK_NAME}"
  local real_binary="$binary"
  local info_plist="${framework_dir}/Info.plist"
  local expected_install_name="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"

  [[ -d "$framework_dir" ]] || die "missing framework bundle: ${framework_dir}"

  if [[ "$layout" == "versioned" ]]; then
    real_binary="${framework_dir}/Versions/A/${FRAMEWORK_NAME}"
    info_plist="${framework_dir}/Versions/A/Resources/Info.plist"
    expected_install_name="@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
    [[ -L "${framework_dir}/Versions/Current" ]] || die "missing Versions/Current symlink in ${framework_dir}"
    [[ -L "$binary" ]] || die "missing top-level ${FRAMEWORK_NAME} symlink in ${framework_dir}"
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

  codesign --verify "$framework_dir" \
    || die "code signature does not verify: ${framework_dir}"

  local dsym="${slice_dir}/dSYMs/${FRAMEWORK_NAME}.framework.dSYM"
  [[ -d "$dsym" ]] || die "missing dSYM: ${dsym}"
  [[ -f "${dsym}/Contents/Resources/DWARF/${FRAMEWORK_NAME}" ]] \
    || die "dSYM has no DWARF binary: ${dsym}"

  verify_module_dir "${framework_dir}/Modules/${MODULE_NAME}.swiftmodule"
}

verify_static_slice() {
  local slice_dir="$1"
  local packaged_library="${slice_dir}/${LIBRARY_BASENAME}"
  local found_binary_module=0

  [[ -f "$packaged_library" ]] || die "missing packaged library: ${packaged_library}"

  while IFS= read -r -d '' _; do
    found_binary_module=1
  done < <(find "${slice_dir}/${MODULE_NAME}.swiftmodule" -name '*.swiftmodule' -print0)
  [[ "$found_binary_module" -eq 1 ]] || die "no binary Swift modules found in ${slice_dir}/${MODULE_NAME}.swiftmodule"

  verify_module_dir "${slice_dir}/${MODULE_NAME}.swiftmodule"
}

verify_slice() {
  local spec="$1"
  local output_identifier layout slice_dir
  output_identifier="$(slice_field "$spec" 1)"
  layout="$(slice_field "$spec" 8)"
  slice_dir="${staging_output}/${output_identifier}"

  log "Verifying ${output_identifier}"

  if is_framework; then
    verify_framework_slice "$slice_dir" "$layout"
  else
    verify_static_slice "$slice_dir"
  fi
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

write_info_plist() {
  local spec output_identifier platform variant layout
  local library_path binary_path

  {
    cat <<'HEAD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
HEAD

    for spec in "${SLICES[@]}"; do
      output_identifier="$(slice_field "$spec" 1)"
      platform="$(slice_field "$spec" 2)"
      variant="$(slice_field "$spec" 3)"
      layout="$(slice_field "$spec" 8)"

      if is_framework; then
        library_path="${FRAMEWORK_NAME}.framework"
        binary_path="${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
        if [[ "$layout" == "versioned" ]]; then
          binary_path="${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
        fi
      else
        library_path="${LIBRARY_BASENAME}"
        binary_path="${LIBRARY_BASENAME}"
      fi

      printf '\t\t<dict>\n'
      printf '\t\t\t<key>BinaryPath</key>\n\t\t\t<string>%s</string>\n' "$binary_path"
      printf '\t\t\t<key>LibraryIdentifier</key>\n\t\t\t<string>%s</string>\n' "$output_identifier"
      printf '\t\t\t<key>LibraryPath</key>\n\t\t\t<string>%s</string>\n' "$library_path"
      if ! is_framework; then
        printf '\t\t\t<key>SwiftModulesPath</key>\n\t\t\t<string>%s.swiftmodule</string>\n' "$MODULE_NAME"
      fi
      if [[ -d "${staging_output}/${output_identifier}/dSYMs" ]]; then
        printf '\t\t\t<key>DebugSymbolsPath</key>\n\t\t\t<string>dSYMs</string>\n'
      fi
      printf '\t\t\t<key>SupportedArchitectures</key>\n\t\t\t<array>\n\t\t\t\t<string>arm64</string>\n\t\t\t</array>\n'
      printf '\t\t\t<key>SupportedPlatform</key>\n\t\t\t<string>%s</string>\n' "$platform"
      if [[ -n "$variant" ]]; then
        printf '\t\t\t<key>SupportedPlatformVariant</key>\n\t\t\t<string>%s</string>\n' "$variant"
      fi
      printf '\t\t</dict>\n'
    done

    cat <<'TAIL'
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
TAIL
  } > "${staging_output}/Info.plist"

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "${staging_output}/Info.plist" >/dev/null \
      || die "generated xcframework Info.plist is malformed"
  fi
}

# Swaps the finished xcframework into place, keeping the old one until the move
# has succeeded so a failure here cannot leave the repository without an
# artifact.
install_output() {
  log "Replacing ${output_path}"
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
  require_toolchain
  resolve_swift_source
  configure_derived_names
  create_work_dir
  stage_sources

  log "Patching staged CMake to emit -module-link-name ${EFFECTIVE_LINK_NAME}"
  patch_cmake_lists "$staged_cmake_lists"

  if is_framework; then
    log "Writing vendor module to suppress the embedded __info_plist"
    write_vendor_module
  fi

  log "Assembling ${package_shape} xcframework in ${staging_output}"
  for spec in "${SLICES[@]}"; do
    build_slice \
      "$(slice_field "$spec" 0)" \
      "$(slice_field "$spec" 4)" \
      "$(slice_field "$spec" 5)" \
      "$(slice_field "$spec" 6)"
    copy_slice "$spec"
  done

  write_info_plist

  for spec in "${SLICES[@]}"; do
    verify_slice "$spec"
  done

  install_output
}

main "$@"
