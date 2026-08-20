#!/usr/bin/env bash

set -euo pipefail

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

MODULE_NAME="_Differentiation"
ORIGINAL_TARGET_NAME="swift_Differentiation"

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
#   * The autolink directive has to name the framework; see patch_cmake_lists.
#
# Note that the identity upstream stamps in -- com.apple.dt.runtime.* -- is not
# itself what triggers any of this. Changing it to a non-Apple identifier was
# tested and made no difference to ITMS-90426; the packaging shape is what
# matters, and for ITMS-90079 what matters is that the section exists at all.
BUNDLE_IDENTIFIER="com.differentiable-swift.differentiation"
BUNDLE_NAME="Differentiation"

# The dynamic library is packaged as a .framework bundle, so it is always built
# shared and always named with the Darwin dylib extension.
LIBRARY_EXTENSION="dylib"

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
output_path=""
keep_work_dir=0

# A swiftlang/swift tag, e.g. swift-6.3.3-RELEASE or
# swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-01-a. Given one, the sources and the
# toolchain are both resolved from it, so they cannot drift apart -- which is
# how a module once got built against the SDK's standard library instead of the
# toolchain's.
swift_version=""

# Path to a .xctoolchain, for testing a compiler that has no swiftlang tag
# (a local build with a patch, say). Overrides swift_version for the compiler
# only; the sources still come from swift_source or the tag.
toolchain_path=""

# The compiler every step uses. Resolved by resolve_toolchain; never `swiftc`
# straight off PATH, which is what let the toolchain and the sources disagree.
swiftc_bin=""

# Where that compiler keeps its standard library, from its own
# -print-target-info. Only the swiftly path fills this in early, so it needs a
# declaration for the `-z` test in resolve_toolchain to be safe under `set -u`.
swift_resource_dir=""

# CFBundleVersion for the framework bundles, derived from the toolchain in
# resolve_bundle_version.
bundle_version=""

ORIGINAL_LIBRARY_BASENAME=""

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
  Tools/build-library.sh --swift-version TAG [--output PATH]
  Tools/build-library.sh --swift-source PATH --toolchain PATH [--output PATH]

Builds an ${MODULE_NAME} XCFramework from a swiftlang/swift source tree and
verifies it. Writes the result to --output; nothing is committed, published or
signed with a real identity here. See Tools/release.sh for publishing.

Given --swift-version, the sources are cloned at that tag and the matching
toolchain is resolved through swiftly, so the compiler, its standard library and
the _Differentiation sources always correspond. Supplying --swift-source or
--toolchain overrides one half of that for local work; it is then your job to
keep them consistent.

Slices are dynamic libraries packaged as .framework bundles, each with a dSYM.
Loose .dylib packaging is not offered: it is rejected with ITMS-90426 and cannot
be made to pass App Store validation.

Options:
  --swift-version TAG  swiftlang/swift tag to build from, e.g.
                       swift-6.3.3-RELEASE or
                       swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-01-a.
                       Clones the sources and selects the toolchain via swiftly,
                       installing it if necessary.
  --swift-source PATH  Use an existing swiftlang/swift checkout instead of
                       cloning. Required when --swift-version is absent.
  --toolchain PATH     Use this .xctoolchain instead of the one --swift-version
                       implies. For testing a locally built compiler.
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
      --swift-version)
        [[ $# -ge 2 ]] || die "--swift-version requires a swiftlang/swift tag"
        swift_version="$2"
        shift 2
        ;;
      --swift-version=*)
        swift_version="${1#*=}"
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

  [[ -n "$swift_version" || -n "$swift_source" ]] \
    || die "one of --swift-version or --swift-source is required"
}

require_toolchain() {
  require_tool cmake
  require_tool ninja
  require_tool xcrun
  require_tool install_name_tool
  require_tool otool
  require_tool plutil
  require_tool dsymutil
}

# Maps a swiftlang/swift tag onto the name swiftly knows the toolchain by.
#
#   swift-6.3.3-RELEASE                            -> 6.3.3
#   swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-01-a  -> 6.4.x-snapshot-2026-08-01
#   swift-DEVELOPMENT-SNAPSHOT-2026-08-01-a        -> main-snapshot-2026-08-01
swiftly_name_for_tag() {
  local tag="$1"

  if [[ "$tag" =~ ^swift-([0-9]+\.[0-9]+\.[0-9]+)-RELEASE$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$tag" =~ ^swift-([0-9]+\.[0-9]+\.x)-DEVELOPMENT-SNAPSHOT-([0-9]{4}-[0-9]{2}-[0-9]{2})(-a)?$ ]]; then
    printf '%s-snapshot-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "$tag" =~ ^swift-DEVELOPMENT-SNAPSHOT-([0-9]{4}-[0-9]{2}-[0-9]{2})(-a)?$ ]]; then
    printf 'main-snapshot-%s' "${BASH_REMATCH[1]}"
  else
    die "cannot derive a swiftly toolchain name from tag '${tag}'; pass --toolchain instead"
  fi
}

# Pins the compiler for the whole run and reads its standard library location.
#
# Everything downstream uses swiftc_bin rather than whatever is on PATH. The two
# are not always the same, and when they differ the module gets built against
# one standard library and consumed against another.
resolve_toolchain() {
  local name toolchain_usr

  if [[ -n "$toolchain_path" ]]; then
    toolchain_usr="$(absolute_existing_dir "${toolchain_path}/usr")"
    swiftc_bin="${toolchain_usr}/bin/swiftc"
    [[ -x "$swiftc_bin" ]] || die "no swiftc in ${toolchain_path}"
  elif [[ -n "$swift_version" ]]; then
    require_tool swiftly
    name="$(swiftly_name_for_tag "$swift_version")"

    log "Ensuring toolchain ${name} is installed"
    swiftly install --assume-yes "$name" >/dev/null \
      || die "swiftly could not install ${name}"

    # runtimeResourcePath is <toolchain>/usr/lib/swift, so the compiler beside
    # it is two levels up. Asking the toolchain locates it without guessing at
    # swiftly's on-disk layout.
    swift_resource_dir="$(swiftly run "+${name}" swiftc -print-target-info \
      | grep -o '"runtimeResourcePath": *"[^"]*"' | cut -d'"' -f4)"
    [[ -n "$swift_resource_dir" ]] || die "could not query toolchain ${name}"
    swiftc_bin="$(dirname "$(dirname "$swift_resource_dir")")/bin/swiftc"
  else
    swiftc_bin="$(command -v swiftc)" || die "no swiftc on PATH"
  fi

  if [[ -z "$swift_resource_dir" ]]; then
    swift_resource_dir="$("$swiftc_bin" -print-target-info \
      | grep -o '"runtimeResourcePath": *"[^"]*"' | cut -d'"' -f4)"
  fi

  [[ -x "$swiftc_bin" ]] || die "resolved compiler is not executable: ${swiftc_bin}"
  [[ -d "$swift_resource_dir" ]] \
    || die "runtimeResourcePath does not name a directory: ${swift_resource_dir}"

  log "Using ${swiftc_bin}"
  log "Using the standard library at ${swift_resource_dir}"
}

# Clones swiftlang/swift at the requested tag when no checkout was supplied.
fetch_swift_source() {
  [[ -z "$swift_source" ]] || return 0

  require_tool git
  swift_source="${work_dir}/swift"

  log "Cloning swiftlang/swift at ${swift_version}"
  git clone --depth 1 --branch "$swift_version" \
    https://github.com/swiftlang/swift.git "$swift_source" >/dev/null 2>&1 \
    || die "could not clone swiftlang/swift at tag ${swift_version}"
}

# Refuses to build sources and a compiler that disagree.
#
# Nothing downstream detects this: the build succeeds and produces a module that
# only fails much later, in someone else's package.
verify_toolchain_matches_sources() {
  local reported

  [[ -n "$swift_version" && -z "$toolchain_path" ]] || return 0

  reported="$("$swiftc_bin" -version 2>/dev/null | head -1)"

  case "$swift_version" in
    swift-*-RELEASE)
      # swift-6.3.3-RELEASE -> "Apple Swift version 6.3.3"
      local want="${swift_version#swift-}"
      want="${want%-RELEASE}"
      [[ "$reported" == *"version ${want}"* ]] \
        || die "toolchain reports '${reported}', which is not ${swift_version}"
      ;;
    *DEVELOPMENT-SNAPSHOT*)
      # Snapshots report a -dev version with no date, so only the major.minor
      # line can be checked here.
      local want="${swift_version#swift-}"
      want="${want%%.x-*}"
      [[ "$reported" == *"version ${want}."* ]] \
        || warn "toolchain reports '${reported}'; expected a ${want}.x snapshot"
      ;;
  esac
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
  ORIGINAL_LIBRARY_BASENAME="lib${ORIGINAL_TARGET_NAME}.${LIBRARY_EXTENSION}"
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

  awk -v module_link_name="$MODULE_NAME" '
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

  if ! grep -q -- "-module-link-name ${MODULE_NAME}" "$tmp"; then
    rm -f "$tmp"
    die "failed to patch ${input} with module link name ${MODULE_NAME}"
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
  local stdlib_dir="${swift_resource_dir}/${sysroot}"
  local swift_flags=""

  # Compile against the toolchain's standard library rather than the SDK's.
  #
  # This module is built with -parse-stdlib, so `import Swift` resolves through
  # the ordinary search paths and CMAKE_OSX_SYSROOT wins, pulling in the stdlib
  # Xcode ships -- which trails a development snapshot by a release. A protocol's
  # requirement signature comes from whichever Swift module is imported, so the
  # module ends up recording associated conformances that consumers using the
  # toolchain's stdlib reject:
  #
  #   error: Listed conformances of 'Array<Element>.DifferentiableView' do not
  #   match current requirement signature of 'AdditiveArithmetic';
  #   1 conformances for 3 requirements
  #
  # The sysroot field doubles as the resource directory's platform subdirectory
  # name, so it selects the right stdlib for each slice.
  #
  # Only toolchains that carry their own platform standard libraries need this.
  # Xcode's has the platform directories but no Swift.swiftmodule in them: on
  # Darwin the standard library ships in the OS and the SDK, and the SDK's copy
  # is the one that matches Xcode's compiler. Testing for the module rather than
  # the directory is what distinguishes the two cases -- the directory exists
  # either way, so a directory test would silently add a search path that
  # resolves nothing.
  if [[ -d "${stdlib_dir}/Swift.swiftmodule" ]]; then
    swift_flags="-I ${stdlib_dir}"
  else
    log "No standard library under ${stdlib_dir}; using the SDK's, which is the one this toolchain matches"
  fi

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
# Reading the generated module interface
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

  version="$bundle_version"

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
    # The effective link name must be the one we injected. Upstream's CMake rule
    # always passes -module-link-name swift_Differentiation, so seeing that value
    # here means the override did not land -- consumers would autolink the wrong
    # library (or, in a framework, the wrong framework).
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

  # Warns rather than fails: an interface produced by a non-Xcode toolchain is
  # still usable by that same toolchain, but Xcode cannot load the binary module
  # and its rebuild from the interface may fail outright.
  producer="$(awk '
    /^\/\/ swift-compiler-version: / {
      sub(/^\/\/ swift-compiler-version: /, "")
      print
      exit
    }' "${interfaces[0]}")"
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

  local dsym="${slice_dir}/dSYMs/${FRAMEWORK_NAME}.framework.dSYM"
  [[ -d "$dsym" ]] || die "missing dSYM: ${dsym}"
  [[ -f "${dsym}/Contents/Resources/DWARF/${FRAMEWORK_NAME}" ]] \
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
  sysroot="$(slice_field "$spec" 4)"
  compiler_target="$(slice_field "$spec" 6)"
  layout="$(slice_field "$spec" 8)"
  slice_dir="${staging_output}/${output_identifier}"

  log "Verifying ${output_identifier}"

  verify_framework_slice "$slice_dir" "$layout"

  verify_module_imports "$slice_dir" "$sysroot" "$compiler_target"
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

      library_path="${FRAMEWORK_NAME}.framework"
      binary_path="${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
      if [[ "$layout" == "versioned" ]]; then
        binary_path="${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
      fi

      printf '\t\t<dict>\n'
      printf '\t\t\t<key>BinaryPath</key>\n\t\t\t<string>%s</string>\n' "$binary_path"
      printf '\t\t\t<key>LibraryIdentifier</key>\n\t\t\t<string>%s</string>\n' "$output_identifier"
      printf '\t\t\t<key>LibraryPath</key>\n\t\t\t<string>%s</string>\n' "$library_path"
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
# Moves the verified bundle to --output, if one was asked for. Without it the
# result stays in the work directory, which is the right default now that the
# artifact is published as a release asset rather than committed.
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
  require_toolchain
  resolve_toolchain
  configure_derived_names
  create_work_dir
  fetch_swift_source
  resolve_swift_source
  verify_toolchain_matches_sources
  resolve_bundle_version
  stage_sources

  log "Patching staged CMake to emit -module-link-name ${MODULE_NAME}"
  patch_cmake_lists "$staged_cmake_lists"

  log "Writing vendor module to suppress the embedded __info_plist"
  write_vendor_module

  log "Assembling the xcframework in ${staging_output}"
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
