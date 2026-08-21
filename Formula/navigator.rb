# The Neon Law Navigator CLI.
#
# THIS FILE IS REWRITTEN BY `scripts/bump.sh` ON EVERY RELEASE. Five values move
# — the version and four sha256 digests — and the script patches exactly those
# lines by anchored regex, then asserts the result. Structure is yours to edit
# by hand; the numbers are not.
#
# A sixth line, `version_scheme`, appears only once it is needed and is likewise
# the script's. Navigator publishes ordinary `YY.M.D` releases and same-day
# `YY.M.D-hotfix.N` prereleases, and this formula follows whichever is newest,
# because it holds ONE version and every `brew install` resolves to it. But
# Homebrew's comparator is not semver — it ranks `26.8.22-hotfix.22` ABOVE
# `26.8.20` — so a bump from a hotfix to its own base version would read as a
# downgrade and `brew upgrade` would refuse to move. `bump.sh` detects that with
# Homebrew's own comparator and increments `version_scheme`, which outranks any
# lower-scheme keg regardless of version. See `scripts/bump.sh`.
#
# Two acquisition paths, because the release publishes two prebuilt
# architectures and no more:
#
#   - arm64 macOS and x86_64 Linux download the archive `deploy.yml` attached to
#     the GitHub Release. Seconds, no toolchain.
#   - Intel macOS and arm64 Linux compile the immutable source tag. Minutes, and
#     a Rust toolchain — but it is the only honest option for a platform whose
#     bytes were never built.
#
# Homebrew is also what makes the macOS binary usable at all. It is unsigned and
# unnotarized, and Gatekeeper blocks a *browser*-downloaded unsigned Mach-O
# outright; brew fetches with curl, which sets no `com.apple.quarantine`
# attribute, so the same bytes run. Signing is still worth doing — this is a
# workaround for its absence, not a replacement.
class Navigator < Formula
  desc "Neon Law Navigator CLI — legal workflow, notation, and deployment tooling"
  homepage "https://github.com/neon-law-foundation/navigator"
  version "26.8.22-hotfix.22"
  # Navigator is AGPL-3.0-only. `-only` and not `-or-later`: the workspace
  # manifest declares exactly that, and a formula that widened it would offer
  # recipients a grant the Foundation did not make.
  license "AGPL-3.0-only"

  on_macos do
    on_arm do
      url "https://github.com/neon-law-foundation/navigator/releases/download/26.8.22-hotfix.22/navigator-26.8.22-hotfix.22-macos.tar.gz"
      sha256 "22c5712edeb82fc1cb62cbcd124d32a32d91bbf8efae3920bccd9d18eabfbaf9"
    end

    on_intel do
      # No prebuilt x86_64 archive exists: `macos-latest` is Apple silicon, and
      # a second full release compile on the slowest runner class is not bought.
      # Compile the source tag instead.
      url "https://github.com/neon-law-foundation/navigator/archive/refs/tags/26.8.22-hotfix.22.tar.gz"
      sha256 "c91743d355fe79424021888b903592a0056a3b74fa5e1f462af9f07e3760f96c"

      depends_on "rust" => :build
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/neon-law-foundation/navigator/releases/download/26.8.22-hotfix.22/navigator-26.8.22-hotfix.22-linux.tar.gz"
      sha256 "4a3e366bda017fd3e2a83e0040c0654a3248ce478bad92e9287cfb6f7e592696"
    end

    on_arm do
      # Same reasoning as Intel macOS: the release publishes x86_64 Linux only.
      url "https://github.com/neon-law-foundation/navigator/archive/refs/tags/26.8.22-hotfix.22.tar.gz"
      sha256 "c91743d355fe79424021888b903592a0056a3b74fa5e1f462af9f07e3760f96c"

      depends_on "rust" => :build
    end
  end

  def install
    # Which of the two URLs above was fetched is decided by the platform, and
    # the unpacked tree is the only thing that can tell us which one landed. A
    # prebuilt archive holds `navigator` at its root; a source tarball holds
    # `Cargo.toml`. Branch on the artifact rather than re-deriving the platform,
    # so the two can never disagree.
    if File.exist?("navigator")
      bin.install "navigator"
    else
      # `cli/build.rs` bakes this into `navigator --version`. Without it a
      # source build reports the workspace placeholder rather than the release
      # it was compiled from, and the `test do` block below would fail — which
      # is the point: the version a binary claims must be the version it is.
      ENV["NAVIGATOR_RELEASE_TAG"] = version.to_s
      system "cargo", "install", *std_cargo_args(path: "cli")
    end

    # LICENSE travels with the install, exactly as it travels with the archive.
    # AGPL-3.0 § 4 conditions the right to convey a copy on giving recipients
    # the licence text, and a recipient holds the binary rather than the
    # repository — that is the whole point of shipping one — so this is where
    # the obligation is met or not at all. Both acquisition paths carry it at
    # their root.
    prefix.install "LICENSE"
  end

  test do
    # The one assertion worth making: the binary reports the version this
    # formula claims. It catches a bump that patched the URL but not the
    # `version` line, a stale asset served under a new tag, and a source build
    # whose release tag never reached `build.rs`.
    assert_match version.to_s, shell_output("#{bin}/navigator --version")
  end
end
