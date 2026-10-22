#!/usr/bin/env bash
# Rebuild the Tiny Talk Android app and install it on the connected phone.
#
# Usage (works from any directory; it finds its own folder):
#   bash android/rebuild-and-install.sh            # build + install, do not open the app
#   bash android/rebuild-and-install.sh --launch   # ...then open the app (it opens on the
#                                                  #    Landing/Onboarding screen; no sound)
#   bash android/rebuild-and-install.sh --fresh    # ...and first wipe the app's data on the
#                                                  #    phone (first-launch behaviour; this also
#                                                  #    forgets keys typed into Settings and
#                                                  #    your consent)
#
# What it checks first (and never prints any key):
#   - the Android Studio JDK, adb and a connected phone
#   - the speech model/library downloads (see android/stt-spike/fetch-models.sh)
#   - whether android/local.secrets.properties has a Groq key baked in (warns if not)
set -euo pipefail

LAUNCH=0
FRESH=0
for arg in "$@"; do
  case "$arg" in
    --launch) LAUNCH=1 ;;
    --fresh)  FRESH=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the android/ directory
cd "$here"

export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
APP_ID="com.jessvb.tinytalk"
APK="app/build/outputs/apk/debug/app-debug.apk"

[ -x "$JAVA_HOME/bin/java" ] || { echo "No JDK at $JAVA_HOME (is Android Studio installed?)" >&2; exit 1; }
[ -x "$ADB" ] || { echo "adb not found at $ADB (finish Android Studio's first-run setup)" >&2; exit 1; }

# 1. Is a phone connected and authorised?
if ! "$ADB" devices | awk 'NR>1 && $2=="device"{found=1} END{exit !found}'; then
  echo "No phone connected. Plug it in, unlock it, accept the 'Allow USB debugging?' prompt," >&2
  echo "then check: $ADB devices   (it should say 'device', not 'unauthorized')" >&2
  exit 1
fi

# 2. Are the speech downloads in place?
missing=0
for f in stt-spike/downloads/libs/sherpa-onnx-static-link-onnxruntime-1.13.8.aar \
         stt-spike/downloads/models/whisper-tiny.en/tiny.en-encoder.int8.onnx \
         stt-spike/downloads/models/whisper-tiny.en/tiny.en-decoder.int8.onnx \
         stt-spike/downloads/models/whisper-tiny.en/tiny.en-tokens.txt; do
  [ -s "$f" ] || { echo "Missing download: android/$f" >&2; missing=1; }
done
if [ "$missing" = 1 ]; then
  echo "Fix: INCLUDE_OPTIONAL=1 bash android/stt-spike/fetch-models.sh" >&2
  exit 1
fi

# 3. Is a key baked in? (checks for a non-empty value only; never prints it)
if [ -f local.secrets.properties ] && grep -qE '^GROQ_API_KEY=.+' local.secrets.properties; then
  echo "Groq key: found in local.secrets.properties (will be built in)."
else
  echo "Groq key: NOT set in android/local.secrets.properties."
  echo "          The app will say 'Elsie needs a key' until you add one in Settings."
fi

# 4. Build.
echo "Building..."
./gradlew :app:assembleDebug -q

[ -f "$APK" ] || { echo "Build finished but $APK is missing" >&2; exit 1; }
echo "Built $APK ($(ls -lh "$APK" | awk '{print $5}'))"

# 5. Install (and optionally reset / launch).
if [ "$FRESH" = 1 ]; then
  echo "Wiping the app's data on the phone (--fresh)..."
  "$ADB" shell pm clear "$APP_ID" >/dev/null 2>&1 || true
fi
echo "Installing..."
"$ADB" install -r "$APK"

if [ "$LAUNCH" = 1 ]; then
  "$ADB" shell am start -n "$APP_ID/.MainActivity" >/dev/null
  echo "Launched."
else
  echo "Installed. Open Tiny Talk on the phone when you are ready (nothing has been started)."
fi
