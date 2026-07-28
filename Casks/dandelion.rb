cask "dandelion" do
  version "0.1.0"
  sha256 :no_check # TODO: replace with the real sha256 once a signed/notarized release .zip is published

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
