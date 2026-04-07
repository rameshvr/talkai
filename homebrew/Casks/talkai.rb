cask "talkai" do
  version "1.0.0"
  sha256 "33da81dd228334a4164a45189c61f1ec099f2b35a9e60b7d799147f7f99c5df5"

  url "https://github.com/rameshvr/talkai/releases/download/v#{version}/TalkAI-v#{version}-mac.dmg"
  name "TalkAI"
  desc "Local AI-powered dictation for macOS — completely on-device"
  homepage "https://github.com/rameshvr/talkai"

  depends_on macos: ">= :tahoe"

  app "TalkAI.app"

  caveats <<~EOS
    TalkAI requires:
    - macOS 26 (Tahoe) or later
    - Apple Silicon (M1 or later)
    - Apple Intelligence enabled in System Settings

    On first launch, grant Microphone and Accessibility permissions
    when prompted. If macOS shows a security warning, right-click
    the app and choose "Open".
  EOS
end
