# Homebrew cask for DockDesk. `version` and `sha256` are rewritten by
# .github/workflows/release.yml whenever a release is published.
#
#   brew tap chdominguez/dockdesk https://github.com/chdominguez/DockDesk
#   brew trust chdominguez/dockdesk   # newer Homebrew only loads casks from trusted taps
#   brew install --cask dockdesk
cask "dockdesk" do
  version "0.2.0"
  sha256 "66cc7226988495eaeca2aa23ad0ac6d9f6b0f9645df08ee848515219f3f9c6dd"

  url "https://github.com/chdominguez/DockDesk/releases/download/v#{version}/DockDesk-#{version}.dmg"
  name "DockDesk"
  desc "Two separate desktops through one cable on a Dell WD19 dock"
  homepage "https://github.com/chdominguez/DockDesk"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "DockDesk.app"

  uninstall quit: "io.github.dockdesk.DockDesk"

  zap trash: [
    "~/Library/Application Support/DockDesk",
    "~/Library/Preferences/io.github.dockdesk.DockDesk.plist",
  ]

  caveats <<~EOS
    DockDesk is not notarized. If macOS refuses to open it, allow it under
    System Settings > Privacy & Security ("Open Anyway"), or run:
      xattr -dr com.apple.quarantine /Applications/DockDesk.app

    Twin mode needs Screen Recording permission. Because the app is ad-hoc
    signed, macOS asks for it again after every update.
  EOS
end
