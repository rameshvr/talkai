cask "talkai" do
  version "1.2.0"
  sha256 "d6f77b6cb91cc8551b7a4576a5b1af6e22351f7159daa420a89d69e7e8a6fc6f"

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
