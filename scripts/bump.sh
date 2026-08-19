#!/usr/bin/env bash
#
# Point `Formula/navigator.rb` at a `YY.M.D` release of
# `neon-law-foundation/navigator`.
#
#   scripts/bump.sh 26.8.17
#   scripts/bump.sh 26.8.20-hotfix.4
#
# Five values move: the version, and the sha256 of each of the three artifacts
# a Navigator release makes available (the macOS archive, the Linux archive,
# and the source tarball, which two platforms compile). The source tarball's
# digest appears twice, once per source-building platform. A sixth may move —
# `version_scheme` — for the reason below.
#
# BOTH RELEASE SHAPES ARE ACCEPTED: an ordinary `YY.M.D` and a same-day
# `YY.M.D-hotfix.N`. Navigator publishes archives for both, and this formula
# holds exactly one version, so the version it holds must be the newest build
# that exists rather than the newest of a particular shape. Refusing hotfixes is
# what left `brew install` serving a 404 for days while three ordinary releases
# in a row failed their end-to-end gate.
#
# WHICH IS WHY `version_scheme` MOVES. Homebrew's comparator is not semver: it
# orders `26.8.20-hotfix.4` ABOVE `26.8.20`, the reverse of the semver §11.3
# ranking Navigator's release tags are built on. So walking this formula from a
# hotfix to its own base version looks to `brew` like a DOWNGRADE — it reports
# the installed keg as current and never upgrades it. `version_scheme` is the
# mechanism Homebrew provides for exactly this (a higher scheme is newer than
# any lower-scheme keg regardless of version), and this script increments it
# whenever the new tag does not sort strictly above the outgoing one. Every bump
# is therefore an upgrade, whatever the shape of either tag.
#
# THE DIGESTS ARE COMPUTED FROM THE BYTES, NEVER COPIED FROM A RELEASE PAGE.
# A sha256 in a formula is the only thing standing between a reader and a
# substituted binary, so it is derived here by downloading the artifact this
# formula will tell every user to download.
#
# The formula's STRUCTURE is hand-maintained and this script must not invent
# it: it patches anchored lines in place and then asserts the result, so a
# structural edit that breaks the patch fails loudly instead of committing a
# formula with a stale digest.
set -euo pipefail

readonly REPO="neon-law-foundation/navigator"
FORMULA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Formula/navigator.rb"
readonly FORMULA

if [[ "$#" -ne 1 ]]; then
    echo "usage: scripts/bump.sh <YY.M.D>" >&2
    exit 2
fi
readonly TAG="$1"

# The same shape `deploy.yml`'s `release-version` job validates, character for
# character: two-digit year, unpadded month and day, and an OPTIONAL unpadded
# `-hotfix.N` prerelease. A tag of any other shape names no release, so
# composing URLs from it would only produce four 404s and a confusing failure
# three steps later. Keeping this identical to the publisher's regex is what
# makes "the tag exists" and "this script accepts it" the same question.
if ! printf '%s' "${TAG}" |
    grep -Eq '^[0-9]{2}\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)(-hotfix\.(0|[1-9][0-9]*))?$'; then
    echo "bump: '${TAG}' is not a YY.M.D or YY.M.D-hotfix.N release version" >&2
    exit 2
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Download and digest one artifact. `--fail` is load-bearing: without it curl
# writes GitHub's 404 page to the file and happily digests THAT, producing a
# formula that installs cleanly right up until someone runs it.
digest() {
    local url="$1" name="$2"
    curl --fail --silent --show-error --location \
        --output "${workdir}/${name}" "${url}"
    shasum -a 256 "${workdir}/${name}" | cut -d' ' -f1
}

echo "==> digesting ${REPO} ${TAG}"
sha_macos="$(digest \
    "https://github.com/${REPO}/releases/download/${TAG}/navigator-${TAG}-macos.tar.gz" \
    macos.tar.gz)"
sha_linux="$(digest \
    "https://github.com/${REPO}/releases/download/${TAG}/navigator-${TAG}-linux.tar.gz" \
    linux.tar.gz)"
sha_source="$(digest \
    "https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz" \
    source.tar.gz)"
echo "    macos  ${sha_macos}"
echo "    linux  ${sha_linux}"
echo "    source ${sha_source}"

# The version currently in the formula, read from the file rather than passed
# in, so a re-run against an already-bumped formula is a no-op instead of a
# corruption.
old="$(sed -n 's/^[[:space:]]*version "\(.*\)"$/\1/p' "${FORMULA}")"
if [[ -z "${old}" ]]; then
    echo "bump: ${FORMULA} has no \`version \"...\"\` line — the formula shape moved" >&2
    exit 1
fi

# The scheme currently in the formula. Absent means 0, which is Homebrew's own
# default for a formula that never declared one.
old_scheme="$(sed -n 's/^[[:space:]]*version_scheme \([0-9]\{1,\}\)$/\1/p' "${FORMULA}")"
: "${old_scheme:=0}"

# Does the new tag sort above the outgoing one BY HOMEBREW'S RULES? Not by
# semver's, and not by this script's idea of either — `brew` is the program that
# will decide whether a reader's `brew upgrade` moves, so `brew` is asked.
# Re-implementing its comparator here is how the two would silently diverge.
#
# A re-run against an already-bumped formula is a no-op, so an unchanged version
# leaves the scheme alone; incrementing it there would republish the same bytes
# as an upgrade on every re-run.
scheme="${old_scheme}"
if [[ "${old}" != "${TAG}" ]]; then
    if brew ruby -e 'require "version"; exit((Version.new(ARGV[0]) <=> Version.new(ARGV[1])).to_i > 0 ? 0 : 1)' \
        "${TAG}" "${old}"; then
        echo "==> ${TAG} sorts above ${old} for brew; version_scheme stays ${scheme}"
    else
        scheme="$((old_scheme + 1))"
        echo "==> ${TAG} does NOT sort above ${old} for brew (a hotfix outranks its own base version there)"
        echo "    version_scheme ${old_scheme} -> ${scheme}, so \`brew upgrade\` still moves"
    fi
fi

# Every occurrence of the old version: the `version` line and both halves of
# each release-asset URL. Dots are escaped so `26.8.17` cannot also match
# `26X8X17`.
escaped="$(printf '%s' "${old}" | sed 's/\./\\./g')"
sed "s/${escaped}/${TAG}/g" "${FORMULA}" > "${workdir}/versioned.rb"

# Write the scheme back. Patch the line if the formula already declares one,
# otherwise insert it after `license` — which is where Homebrew's
# `FormulaAudit/ComponentsOrder` cop expects it, so `brew style` stays green.
# A scheme of 0 is Homebrew's default and stays unwritten: a formula carrying a
# no-op `version_scheme 0` reads as though someone had a reason for it.
if [[ "${scheme}" -ne 0 ]]; then
    if grep -q '^[[:space:]]*version_scheme [0-9]\{1,\}$' "${workdir}/versioned.rb"; then
        sed "s/^\([[:space:]]*\)version_scheme [0-9]\{1,\}$/\1version_scheme ${scheme}/" \
            "${workdir}/versioned.rb" > "${workdir}/scheme.rb"
    else
        sed "s/^\([[:space:]]*\)license \(.*\)$/\1license \2\n\1version_scheme ${scheme}/" \
            "${workdir}/versioned.rb" > "${workdir}/scheme.rb"
    fi
    mv "${workdir}/scheme.rb" "${workdir}/versioned.rb"
fi

# Each `sha256` line takes the digest of the artifact the `url` line ABOVE it
# names. Matching on the URL rather than on position means reordering the
# platform blocks cannot silently pair a digest with the wrong download.
awk \
    -v macos="${sha_macos}" \
    -v linux="${sha_linux}" \
    -v source="${sha_source}" '
    /^[[:space:]]*url "/ {
        if ($0 ~ /-macos\.tar\.gz"$/)      { pending = macos }
        else if ($0 ~ /-linux\.tar\.gz"$/) { pending = linux }
        else                               { pending = source }
        print; next
    }
    /^[[:space:]]*sha256 "/ && pending != "" {
        sub(/"[0-9a-f]*"/, "\"" pending "\"")
        print; pending = ""; next
    }
    { print }
' "${workdir}/versioned.rb" > "${workdir}/navigator.rb"

# ---- assertions -----------------------------------------------------------
# The patch is regex over a hand-maintained file. Everything below exists
# because a silent partial patch publishes a formula that resolves — a URL for
# one release carrying the digest of another — and Homebrew reports that as a
# checksum mismatch on the USER's machine, not here.
fail() { echo "bump: $1" >&2; exit 1; }

# No leftover of the outgoing version anywhere in the file.
#
# Checked against a copy with every occurrence of the NEW tag stripped out,
# because an ordinary version is a prefix of its own hotfix: bumping `26.8.20`
# to `26.8.20-hotfix.4` writes a correct formula in which a bare `grep 26.8.20`
# matches on every patched line. Stripping the new tag first makes the question
# the one actually worth asking — is any `26.8.20` left that is not part of a
# `26.8.20-hotfix.4`?
escaped_tag="$(printf '%s' "${TAG}" | sed 's/\./\\./g')"
if [[ "${old}" != "${TAG}" ]] &&
    sed "s/${escaped_tag}//g" "${workdir}/navigator.rb" | grep -q "${escaped}"; then
    fail "the previous version ${old} still appears after the patch"
fi

grep -q "^[[:space:]]*version \"${TAG}\"$" "${workdir}/navigator.rb" ||
    fail "the \`version\` line was not updated to ${TAG}"

# `version_scheme` is what keeps `brew upgrade` moving across a tag that sorts
# backwards, so a patch that dropped it, duplicated it, or walked it BACKWARDS
# would strand every installed keg — silently, and only on a reader's machine.
schemes="$(grep -c '^[[:space:]]*version_scheme [0-9]\{1,\}$' "${workdir}/navigator.rb" || true)"
if [[ "${scheme}" -eq 0 ]]; then
    [[ "${schemes}" -eq 0 ]] ||
        fail "scheme 0 is Homebrew's default and must stay unwritten, found ${schemes} \`version_scheme\` line(s)"
else
    [[ "${schemes}" -eq 1 ]] ||
        fail "expected exactly 1 \`version_scheme\` line, found ${schemes}"
    grep -q "^[[:space:]]*version_scheme ${scheme}$" "${workdir}/navigator.rb" ||
        fail "the \`version_scheme\` line was not written as ${scheme}"
fi
[[ "${scheme}" -ge "${old_scheme}" ]] ||
    fail "version_scheme went backwards, ${old_scheme} -> ${scheme} — a lower scheme is OLDER than every installed keg"

urls="$(grep -c '^[[:space:]]*url "' "${workdir}/navigator.rb")"
digests="$(grep -c '^[[:space:]]*sha256 "' "${workdir}/navigator.rb")"
[[ "${urls}" -eq 4 ]] || fail "expected 4 \`url\` lines, found ${urls}"
[[ "${digests}" -eq 4 ]] || fail "expected 4 \`sha256\` lines, found ${digests}"

while read -r line; do
    printf '%s' "${line}" | grep -q "${TAG}" ||
        fail "a url line does not name ${TAG}: ${line}"
done < <(grep '^[[:space:]]*url "' "${workdir}/navigator.rb")

# The placeholder the formula ships with before its first bump, and the shape
# any unpatched digest would keep.
if grep -q 'sha256 "0\{64\}"' "${workdir}/navigator.rb"; then
    fail "a sha256 is still the all-zero placeholder — one url did not match a known artifact"
fi

for expected in "${sha_macos}" "${sha_linux}" "${sha_source}"; do
    grep -q "sha256 \"${expected}\"" "${workdir}/navigator.rb" ||
        fail "the computed digest ${expected} did not reach the formula"
done

cp "${workdir}/navigator.rb" "${FORMULA}"
echo "==> ${FORMULA} now points at ${TAG}"
