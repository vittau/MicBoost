cask "micboost" do
  version "X.Y.Z"
  sha256 "SHA256"

  url "https://github.com/vittau/MicBoost/releases/download/v#{version}/MicBoost-#{version}.zip"
  name "MicBoost"
  desc "Menu bar microphone booster and EQ that routes to BlackHole"
  homepage "https://github.com/vittau/MicBoost"

  depends_on macos: ">= :sonoma"
  depends_on cask: "blackhole-2ch"

  app "MicBoost.app"

  uninstall quit: "io.github.vittau.MicBoost"

  zap trash: [
    "~/Library/Preferences/io.github.vittau.MicBoost.plist",
  ]

  caveats <<~EOS
    MicBoost is not notarized. On first launch macOS will block it:
    open System Settings › Privacy & Security and click "Open Anyway".
    BlackHole 2ch is installed as a dependency and is NOT removed when
    MicBoost is uninstalled (other apps may use it).
  EOS
end
