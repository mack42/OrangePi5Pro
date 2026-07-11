#!/usr/bin/env bash
# Publish a GitHub release for the images built by 02-build-resolute.sh.
# Tags the release, (re)generates checksums, uploads the image(s), and
# attaches release notes. Idempotent: re-running on an existing release adds
# or refreshes assets (and updates notes if --notes is given), so you can
# publish the desktop image first and attach the minimal one later.
#
# Usage:
#   ./04-release.sh v1.7.0                      # both variants that exist for this tag
#   ./04-release.sh v1.7.0 --notes notes.md     # use a notes file (else auto-generated)
#   ./04-release.sh v1.7.0 --title "v1.7.0 — foo"
#   ./04-release.sh v1.7.0 --draft              # create as a draft, don't publish yet
#
# Prerequisites:
#   - GitHub CLI installed and authenticated:  gh auth login
#   - Images already built WITH a matching VERSION, e.g.:
#       VERSION=v1.7.0 ./02-build-resolute.sh --desktop   # -> opi5pro-v1.7.0-desktop.img.xz
#       VERSION=v1.7.0 ./02-build-resolute.sh             # -> opi5pro-v1.7.0-minimal.img.xz
#
# Output dir: ~/armbian-build/framework/output/images (override with WORK=).

set -euo pipefail

WORK="${WORK:-$HOME/armbian-build}"
imgdir="${WORK}/framework/output/images"

VERSION=""
NOTES="${NOTES:-}"
TITLE="${TITLE:-}"
create_flags=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes)   NOTES="$2"; shift 2 ;;
        --notes=*) NOTES="${1#*=}"; shift ;;
        --title)   TITLE="$2"; shift 2 ;;
        --title=*) TITLE="${1#*=}"; shift ;;
        --draft)   create_flags+=(--draft); shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        v[0-9]*|[0-9]*) VERSION="$1"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$VERSION" ]] || { echo "ERROR: version required, e.g. ./04-release.sh v1.7.0" >&2; exit 1; }
[[ "$VERSION" == v* ]] || VERSION="v${VERSION}"
[[ -n "$TITLE" ]] || TITLE="$VERSION"

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh (GitHub CLI) not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated — run: gh auth login" >&2; exit 1; }

# Collect whichever variants were built for this version, (re)generating the
# .sha256 next to each so `sha256sum -c <file>.sha256` works after download.
assets=()
for variant in desktop minimal; do
    img="${imgdir}/opi5pro-${VERSION}-${variant}.img.xz"
    if [[ -f "$img" ]]; then
        ( cd "$imgdir" && sha256sum "$(basename "$img")" > "$(basename "$img").sha256" )
        assets+=( "$img" "${img}.sha256" )
        [[ -f "${img%.img.xz}.img.txt" ]] && assets+=( "${img%.img.xz}.img.txt" )
        echo ">>> found ${variant}: $(basename "$img")"
    else
        echo ">>> (no ${variant} image for ${VERSION} in ${imgdir} — skipping)"
    fi
done
[[ ${#assets[@]} -gt 0 ]] || { echo "ERROR: no opi5pro-${VERSION}-*.img.xz images in ${imgdir}" >&2; exit 1; }

# Notes: a file if given, else let GitHub auto-generate from commits/PRs.
notes_flags=()
if [[ -n "$NOTES" ]]; then
    [[ -f "$NOTES" ]] || { echo "ERROR: notes file not found: $NOTES" >&2; exit 1; }
    notes_flags=( --notes-file "$NOTES" )
else
    notes_flags=( --generate-notes )
fi

if gh release view "$VERSION" >/dev/null 2>&1; then
    echo ">>> release ${VERSION} exists — refreshing assets"
    gh release upload "$VERSION" "${assets[@]}" --clobber
    if [[ -n "$NOTES" ]]; then
        echo ">>> updating notes + title"
        gh release edit "$VERSION" --title "$TITLE" --notes-file "$NOTES"
    fi
else
    echo ">>> creating release ${VERSION}"
    gh release create "$VERSION" --target main --latest --title "$TITLE" \
        "${create_flags[@]}" "${notes_flags[@]}" "${assets[@]}"
fi

echo ">>> done: $(gh release view "$VERSION" --json url -q .url)"
