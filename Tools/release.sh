#!/usr/bin/env bash

set -euo pipefail

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

MODULE_NAME="_Differentiation"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd -P)"
manifest="${repo_root}/Package.swift"

# ----------------------------------------------------------------------------
# Mutable state
# ----------------------------------------------------------------------------

swift_version=""
package_version=""
dry_run=0
work_dir=""
artifact_path=""
remote="origin"
repository=""

# ----------------------------------------------------------------------------
# Diagnostics
# ----------------------------------------------------------------------------

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

usage() {
  cat <<EOF
Usage:
  Tools/release.sh --artifact PATH --swift-version TAG --package-version VERSION

Publishes an ${MODULE_NAME} XCFramework as a release asset and points
Package.swift at it. Build it first with Tools/build-library.sh.

The artifact is not committed. Consumers fetch it over HTTPS and SwiftPM checks
it against the recorded SHA256, so the checksum is what makes the download
trustworthy -- there is nothing for a signature to add.

Options:
  --artifact PATH          The .xcframework to publish, from build-library.sh.
  --swift-version TAG      Provenance label only, e.g. swift-6.3.3-RELEASE. Used
                           for the asset filename and the release notes; nothing
                           checks it against what actually built the artifact, so
                           it is on you to keep it honest -- particularly when
                           the sources carry local patches or the toolchain is
                           not the one the tag names.
  --package-version VER    Tag to publish this package under, e.g. 603.3.0 or
                           604.0.0-prerelease-4. Not derived from the Swift tag:
                           swift-differentiation selects between these with
                           #if compiler(...), so the mapping is a decision, not
                           a computation.
  --dry-run                Zip and print what would be published, without
                           touching git or GitHub.
  --remote NAME            Git remote to push and publish to; defaults to origin.
  -h, --help               Show this help.

Ordering note: the manifest is committed with a URL for a release that does not
exist yet. That is fine -- the URL only has to resolve when a consumer resolves
the package, which is after the release is created a few steps later.
EOF
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --swift-version)
        [[ $# -ge 2 ]] || die "--swift-version requires a tag"
        swift_version="$2"
        shift 2
        ;;
      --swift-version=*)
        swift_version="${1#*=}"
        shift
        ;;
      --package-version)
        [[ $# -ge 2 ]] || die "--package-version requires a version"
        package_version="$2"
        shift 2
        ;;
      --package-version=*)
        package_version="${1#*=}"
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --remote)
        [[ $# -ge 2 ]] || die "--remote requires a git remote name"
        remote="$2"
        shift 2
        ;;
      --remote=*)
        remote="${1#*=}"
        shift
        ;;
      --artifact)
        [[ $# -ge 2 ]] || die "--artifact requires a path to an .xcframework"
        artifact_path="$2"
        shift 2
        ;;
      --artifact=*)
        artifact_path="${1#*=}"
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

  [[ -n "$artifact_path" ]] || die "--artifact is required; build one with Tools/build-library.sh"
  [[ -n "$swift_version" ]] || die "--swift-version is required"
  [[ -n "$package_version" ]] || die "--package-version is required"
}

# Sets repository slug from a remote name, handles both SSH and HTTPS forms.
resolve_repository() {
  local url

  url="$(git -C "$repo_root" remote get-url --push "$remote")" \
    || die "no git remote named ${remote}"

  url="${url%.git}"
  url="${url#*://}"           # drop any scheme
  url="${url#*@}"             # drop any user@
  repository="${url#*[:/]}"   # drop the host, leaving owner/name

  log "Publishing to ${repository} via remote ${remote}"
}

require_clean_checkout() {
  [[ "$dry_run" -eq 1 ]] && return 0

  git -C "$repo_root" diff --quiet && git -C "$repo_root" diff --cached --quiet \
    || die "working tree is dirty; commit or stash before releasing"

  git -C "$repo_root" rev-parse "$package_version" >/dev/null 2>&1 \
    && die "tag ${package_version} already exists"

  return 0
}

# ----------------------------------------------------------------------------
# Build and package
# ----------------------------------------------------------------------------

# Zips with ditto rather than zip: the framework bundles contain symlinks
# (Versions/Current, and the top-level binary pointing into it) that plain zip
# flattens, which breaks the bundle on extraction.
zip_artifact() {
  local xcframework="${work_dir}/${MODULE_NAME}.xcframework"

  [[ -d "$artifact_path" ]] || die "not a directory: ${artifact_path}"
  cp -R "$artifact_path" "$xcframework"

  log "Compressing ${artifact_path}"
  ( cd "$work_dir" \
    && ditto -c -k --sequesterRsrc --keepParent \
         "${MODULE_NAME}.xcframework" "$(asset_name)" )
}

# The toolchain is in the filename so a release page shows at a glance which
# compiler an artifact belongs to, and so several can coexist under one tag.
asset_name() {
  printf '%s-%s.xcframework.zip' "$MODULE_NAME" "$swift_version"
}

asset_url() {
  printf 'https://github.com/%s/releases/download/%s/%s' \
    "$repository" "$package_version" "$(asset_name)"
}

# A hyphen after the numeric core marks a semver prerelease, e.g.
# 604.0.0-prerelease-4 vs. 603.3.0. Prereleases must not be marked "Latest"
# on the GitHub releases page.
is_prerelease() {
  [[ "$package_version" == *-* ]]
}

# ----------------------------------------------------------------------------
# Publish
# ----------------------------------------------------------------------------

update_manifest() {
  local url="$1" checksum="$2"

  grep -q 'url: "' "$manifest" \
    || die "${manifest} has no binaryTarget url to update; is it still a path-based target?"

  # Only one binaryTarget exists, so anchoring on the key is enough.
  sed -i '' -E \
    -e "s|(url: \")[^\"]*(\")|\1${url}\2|" \
    -e "s|(checksum: \")[^\"]*(\")|\1${checksum}\2|" \
    "$manifest"

  grep -q "$checksum" "$manifest" || die "failed to write the checksum into ${manifest}"
}

publish() {
  local zip="${work_dir}/$(asset_name)"
  local checksum url

  checksum="$(swift package --package-path "$repo_root" compute-checksum "$zip")"
  url="$(asset_url)"

  log "Asset:    $(asset_name)"
  log "URL:      ${url}"
  log "Checksum: ${checksum}"

  if [[ "$dry_run" -eq 1 ]]; then
    log "Dry run; leaving ${zip} in place and not touching git"
    return 0
  fi

  update_manifest "$url" "$checksum"

  git -C "$repo_root" add Package.swift
  git -C "$repo_root" commit -m "release: ${package_version} (${swift_version})"
  git -C "$repo_root" tag "$package_version"
  git -C "$repo_root" push --atomic "$remote" HEAD "$package_version"

  local release_flags=()
  is_prerelease && release_flags+=(--prerelease)

  if ! gh release create "$package_version" "$zip" \
    --repo "$repository" \
    --title "$package_version" \
    --notes "Built from swiftlang/swift at \`${swift_version}\`." \
    "${release_flags[@]}"; then
    die "gh release create failed for ${package_version}"
  fi

  log "Published ${package_version}"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  parse_arguments "$@"

  require_tool ditto
  require_tool git
  require_tool swift
  [[ "$dry_run" -eq 1 ]] || require_tool gh

  require_clean_checkout
  resolve_repository

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/swift-differentiation-release.XXXXXX")"
  trap cleanup EXIT

  zip_artifact
  publish
}

cleanup() {
  if [[ "$dry_run" -eq 1 ]]; then
    log "Kept ${work_dir}"
  else
    rm -rf "$work_dir"
  fi
}

main "$@"
