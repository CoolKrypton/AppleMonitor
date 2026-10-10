#!/usr/bin/env bash
#
# iOS build helper - the counterpart of AndroidMonitor's build_apk.cmd and
# build_and_install.cmd.
#
# MUST be run on macOS. Neither Xcode nor the iOS toolchain exists anywhere
# else, which is why the project is handed over as sources rather than as a
# prebuilt binary.
#
#   ./build_ios.sh            release build, unsigned .app (sanity check: it compiles)
#   ./build_ios.sh sim        boot the Simulator and run there (no signing at all)
#   ./build_ios.sh run        run on the first connected iPhone / iPad (needs a signing team)
#   ./build_ios.sh archive    release build + .ipa for TestFlight / App Store
#   ./build_ios.sh clean      flutter clean + pod deintegrate
#
set -euo pipefail

cd "$(dirname "$0")"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
  die "This script only runs on macOS. On Windows, copy this directory to the Mac first."
fi

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH. Install the Flutter SDK and reopen the shell."
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is not on PATH. Install Xcode, then: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"

say "flutter $(flutter --version | head -1 | awk '{print $2}')  /  $(xcodebuild -version | head -1)"

MODE="${1:-build}"

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------

if [ "$MODE" = "clean" ]; then
  say "flutter clean"
  flutter clean
  if [ -d ios/Pods ]; then
    if command -v pod >/dev/null 2>&1; then
      say "pod deintegrate"
      (cd ios && pod deintegrate || true)
    fi
    say "removing ios/Pods and ios/Podfile.lock"
    rm -rf ios/Pods ios/Podfile.lock
  fi
  say "done"
  exit 0
fi

# ---------------------------------------------------------------------------
# dependencies
#
# `flutter pub get` is also what regenerates Flutter/Generated.xcconfig and the
# generated plugin registrant, both of which the Xcode project needs before it
# can even be opened - so it always runs first.
# ---------------------------------------------------------------------------

say "flutter pub get"
flutter pub get

if [ -f ios/Podfile ]; then
  if command -v pod >/dev/null 2>&1; then
    say "pod install"
    (cd ios && pod install)
  else
    die "CocoaPods is missing but ios/Podfile exists (the shared_preferences plugin is a pod).
     Install it with one of:
       sudo gem install cocoapods
       brew install cocoapods"
  fi
fi

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

case "$MODE" in
  build)
    # --no-codesign deliberately: this proves the whole toolchain compiles
    # without requiring an Apple developer team to be configured first.
    say "flutter build ios --release --no-codesign"
    flutter build ios --release --no-codesign
    say "artifact: $(pwd)/build/ios/iphoneos/Runner.app"
    warn "unsigned - Xcode signs it when you 'run' on a device, or use './build_ios.sh archive'."
    ;;

  sim)
    # The Simulator exercises the whole UI without any signing identity, but it
    # is a poor test of the networking: it shares the Mac's network stack, so it
    # will see hosts on the Mac's LAN. It is still the fastest way to check that
    # a change builds and renders.
    say "opening the iOS Simulator"
    open -a Simulator || die "could not open the Simulator - is Xcode installed?"
    sleep 4
    say "flutter run"
    flutter run
    ;;

  run)
    say "attached devices:"
    flutter devices
    say "flutter run  (pick the iPhone / iPad when prompted)"
    flutter run
    ;;

  archive)
    # Requires, once, in Xcode: Runner target -> Signing & Capabilities ->
    # select your Team. Flutter cannot set that for you.
    say "flutter build ipa --release"
    flutter build ipa --release
    say "artifact: $(pwd)/build/ios/ipa/"
    ;;

  *)
    die "unknown mode '$MODE' - expected one of: build | sim | run | archive | clean"
    ;;
esac
