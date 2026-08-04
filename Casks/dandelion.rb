cask "dandelion" do
  version "0.2.0"
  sha256 "5a2cb763098d13ac90f28582f67ccb7793aae6d293a19359d2ed010e98d38901"

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
