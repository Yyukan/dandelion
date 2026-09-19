cask "dandelion" do
  version "0.5.0"
  sha256 "e6cfd8fb84fa3def03aac8bc4c28f5b76aa66dccdeb02102efce5a68d7697448"

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
