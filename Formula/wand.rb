# Homebrew formula for Wand. Builds from source, so no notarized binary is
# needed. Install directly (no tap required):
#   brew install https://raw.githubusercontent.com/hanfann/wand/main/Formula/wand.rb
# Bump `url`/`sha256` for each tagged release.
class Wand < Formula
  desc "Autonomous iOS Simulator E2E driver for AI agents"
  homepage "https://github.com/hanfann/wand"
  url "https://github.com/hanfann/wand/archive/refs/tags/v0.1.3.tar.gz"
  sha256 "e5dfb46541eb4b8abaddeea1fa7244268151fb909022fc465b925020dda22907"
  license "MIT"
  head "https://github.com/hanfann/wand.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/wand"
    (pkgshare/"skills/wand").install "skills/wand/SKILL.md"
  end

  def caveats
    <<~EOS
      Finish setup (installs the Claude Code skill + registers the MCP server):
        wand setup

      Then boot a simulator, and:  wand info && wand ui
    EOS
  end

  test do
    assert_match "wand", shell_output("#{bin}/wand help")
  end
end
