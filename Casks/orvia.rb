cask "orvia" do
  version :latest
  sha256 :no_check

  url "https://github.com/richardfariax/orvia/releases/latest/download/Orvia.dmg"
  name "Orvia"
  desc "Clipboard, voice, system insights, and safe cleanup"
  homepage "https://github.com/richardfariax/orvia"

  depends_on macos: :golden_gate

  app "Orvia.app"

  zap trash: [
    "~/Library/Application Support/Orvia",
    "~/Library/Caches/com.richadfarias.orvia",
    "~/Library/HTTPStorages/com.richadfarias.orvia",
    "~/Library/Preferences/com.richadfarias.orvia.plist",
    "~/Library/Saved Application State/com.richadfarias.orvia.savedState",
  ]
end
