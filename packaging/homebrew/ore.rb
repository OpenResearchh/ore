# Homebrew cask for ORE.
#
# This file is the source of truth; it is copied to
# OpenResearchh/homebrew-tap as Casks/ore.rb by certify-release.sh, which also
# rewrites `version` and `sha256`. Keeping the template in this repository
# means the packaging is reviewed alongside the code it packages.
#
#   brew install --cask openresearchh/tap/ore
#
# On the quarantine strip in postflight: Homebrew Cask attaches
# com.apple.quarantine to everything it downloads, and on macOS 15+ that
# blocks an ad-hoc signed app outright — ORE has no Apple Developer ID yet.
# Removing the attribute here is what makes `brew install` work without the
# user having to know to pass --no-quarantine. Homebrew's maintainers
# discourage this and homebrew/cask proper would reject the cask for it, which
# is precisely why ORE lives in its own tap for now. Once ORE is notarized
# this block goes away and the cask can be submitted upstream.
cask "ore" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/OpenResearchh/ore/releases/download/v#{version}/ORE-#{version}.zip",
      verified: "github.com/OpenResearchh/ore/"
  name "ORE"
  desc "Run several coding agents in parallel, each in its own git worktree"
  homepage "https://openresearchh.com/ore"

  depends_on macos: ">= :sonoma"
  # ORE ships an arm64-only build today. Without this, Homebrew would happily
  # install an app that cannot launch at all on an Intel Mac.
  depends_on arch: :arm64

  # ORE updates itself. Without this, `brew upgrade` sees a bundle newer than
  # the cask's version and reinstalls the older one over it — a downgrade the
  # user never asked for, every time the tap lags behind a release.
  auto_updates true

  app "ORE.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ORE.app"],
                   sudo: false

    # Records the install channel for anonymous analytics (see PRIVACY.md).
    # Deliberately written to ~/ore rather than into the bundle: writing inside
    # ORE.app after it is signed breaks the code signature seal, and the
    # in-app updater replaces the whole bundle on every update.
    ore_home = File.expand_path("~/ore")
    FileUtils.mkdir_p(ore_home)
    File.write(File.join(ore_home, "install-channel"), "homebrew")
  end

  uninstall quit: "dev.ore.OreMac"

  zap trash: [
    "~/ore",
    "~/Library/Preferences/dev.ore.OreMac.plist",
    "~/Library/Caches/dev.ore.OreMac",
  ]
end
