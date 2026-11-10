# Homebrew formula for Wand. Builds from source, so no notarized binary is
# needed. Install directly (no tap required):
#   brew install https://raw.githubusercontent.com/hanfann/wand/main/Formula/wand.rb
# Bump `url`/`sha256` for each tagged release.
class Wand < Formula
  desc "Agent-driven Apple Simulator automation (iOS, iPadOS, watchOS)"
  homepage "https://github.com/hanfann/wand"
  url "https://github.com/hanfann/wand/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "6c3ec18c78c5cf9a4979ef6124d7ec698eff76f0dd6786c3c82d532068c701c8"
  license "MIT"
  head "https://github.com/hanfann/wand.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/wand"
    pkgshare.install "THIRD_PARTY_NOTICES" if File.exist?("THIRD_PARTY_NOTICES")
    (pkgshare/"skills/wand").install "skills/wand/SKILL.md"
  end

  def caveats
    <<~EOS
      Install the shared Claude/Codex skill:
        wand setup

      Optional one-tool MCP: wand setup --mcp
      Then select a simulator: wand --udid <ID> info
    EOS
  end

  test do
    assert_match "wand", shell_output("#{bin}/wand help")
  end
end
