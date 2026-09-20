cask "dandelion" do
  version "0.5.1"
  sha256 "21910e3a169b9ba6b7116aa2db0faafd26fc148dd8506fecc547476c439c9c31"

  url "https://github.com/Yyukan/dandelion/releases/download/v#{version}/Dandelion.zip"
  name "Dandelion"
  desc "Menu bar app for OpenCode Zen balance, Go usage and model pricing"
  homepage "https://github.com/Yyukan/dandelion"

  depends_on macos: ">= :tahoe"

  app "Dandelion.app"

  zap trash: [
    "~/Library/Application Support/Dandelion",
    "~/Library/Preferences/nl.ostconsultancy.Dandelion.plist",
  ]
end
