#!/usr/bin/env bash
#
# Point `Formula/navigator.rb` at a `YY.M.D` release of
# `neon-law-foundation/navigator`.
#
#   scripts/bump.sh 26.8.17
#
# Five values move: the version, and the sha256 of each of the three artifacts
# a Navigator release makes available (the macOS archive, the Linux archive,
# and the source tarball, which two platforms compile). The source tarball's
# digest appears twice, once per source-building platform.
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
readonly FORMULA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Formula/navigator.rb"

if [ "$#" -ne 1 ]; then
    echo "usage: scripts/bump.sh <YY.M.D>" >&2
    exit 2
fi
readonly TAG="$1"

# The same shape `deploy.yml`'s `release-version` job validates: two-digit
# year, unpadded month and day, exactly three components. A tag of any other
# shape names no release, so composing URLs from it would only produce four
# 404s and a confusing failure three steps later.
if ! printf '%s' "${TAG}" | grep -Eq '^[0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2}$'; then
    echo "bump: '${TAG}' is not a YY.M.D release version" >&2
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
if [ -z "${old}" ]; then
    echo "bump: ${FORMULA} has no \`version \"...\"\` line — the formula shape moved" >&2
    exit 1
fi

# Every occurrence of the old version: the `version` line and both halves of
# each release-asset URL. Dots are escaped so `26.8.17` cannot also match
# `26X8X17`.
escaped="$(printf '%s' "${old}" | sed 's/\./\\./g')"
sed "s/${escaped}/${TAG}/g" "${FORMULA}" > "${workdir}/versioned.rb"

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

if [ "${old}" != "${TAG}" ] && grep -q "${escaped}" "${workdir}/navigator.rb"; then
    fail "the previous version ${old} still appears after the patch"
fi

grep -q "^[[:space:]]*version \"${TAG}\"$" "${workdir}/navigator.rb" ||
    fail "the \`version\` line was not updated to ${TAG}"

urls="$(grep -c '^[[:space:]]*url "' "${workdir}/navigator.rb")"
digests="$(grep -c '^[[:space:]]*sha256 "' "${workdir}/navigator.rb")"
[ "${urls}" -eq 4 ] || fail "expected 4 \`url\` lines, found ${urls}"
[ "${digests}" -eq 4 ] || fail "expected 4 \`sha256\` lines, found ${digests}"

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
