# Homebrew cask for TwinDesk. `version` and `sha256` are rewritten by
# .github/workflows/release.yml whenever a release is published.
#
#   brew tap chdominguez/twindesk https://github.com/chdominguez/TwinDesk
#   brew install --cask twindesk
cask "twindesk" do
  version "0.1.0"
  sha256 "ea445e48f9903d854fd5c12f7b29505198678861939ff648e40f7afc4e71cab4"

  url "https://github.com/chdominguez/TwinDesk/releases/download/v#{version}/TwinDesk-#{version}.dmg"
  name "TwinDesk"
  desc "Two separate desktops through one cable on a Dell WD19 dock"
  homepage "https://github.com/chdominguez/TwinDesk"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "TwinDesk.app"

  uninstall quit: "io.github.twindesk.TwinDesk"

  zap trash: [
    "~/Library/Application Support/TwinDesk",
    "~/Library/Preferences/io.github.twindesk.TwinDesk.plist",
  ]

  caveats <<~EOS
    TwinDesk is not notarized. If macOS refuses to open it, allow it under
    System Settings > Privacy & Security ("Open Anyway"), or run:
      xattr -dr com.apple.quarantine /Applications/TwinDesk.app

    Twin mode needs Screen Recording permission. Because the app is ad-hoc
    signed, macOS asks for it again after every update.
  EOS
end
