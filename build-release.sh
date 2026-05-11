#!/bin/bash
# Build signed v2rayNG APKs with a custom Xray-core fork and upload to a GitHub release.
#
# Usage:
#   KEYSTORE_PASSWORD='...' ./build-release.sh <version>
#   e.g. KEYSTORE_PASSWORD='...' ./build-release.sh 2.1.7-fed.2
#
# Environment overrides (defaults shown):
#   XRAY_CORE_PATH=/home/stalk/fedarisha/Xray-core
#   KEYSTORE_PATH=$HOME/.android-keystore/voltara13-v2rayng.jks
#   KEY_ALIAS=voltara13
#   KEY_PASSWORD=$KEYSTORE_PASSWORD
#   TARGET_REPO=voltara13/v2rayNG
#   ANDROID_HOME=$HOME/Android/Sdk
#   NDK_VERSION=29.0.14206865
#   JAVA_HOME=$HOME/.local/jdks/jdk-21.0.11+10
#
# Requirements (must be installed): git, go, curl, gh (authenticated), Android SDK + NDK, JDK 21.
# gomobile is auto-installed if missing.

set -euo pipefail

VERSION="${1:?Usage: build-release.sh <version> (e.g. 2.1.7-fed.2)}"

TARGET_REPO="${TARGET_REPO:-voltara13/v2rayNG}"
XRAY_CORE_PATH="${XRAY_CORE_PATH:-/home/stalk/fedarisha/Xray-core}"
KEYSTORE_PATH="${KEYSTORE_PATH:-$HOME/.android-keystore/voltara13-v2rayng.jks}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:?Set KEYSTORE_PASSWORD env}"
KEY_ALIAS="${KEY_ALIAS:-voltara13}"
KEY_PASSWORD="${KEY_PASSWORD:-$KEYSTORE_PASSWORD}"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/$NDK_VERSION}"
export NDK_HOME="$ANDROID_NDK_HOME"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/jdks/jdk-21.0.11+10}"
export PATH="$JAVA_HOME/bin:$HOME/go/bin:$PATH"
# WSL Java sometimes prefers IPv6 and fails DNS for gradle/maven mirrors.
export _JAVA_OPTIONS="${_JAVA_OPTIONS:--Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

[ -d "$XRAY_CORE_PATH" ] || { echo "Xray-core not found at $XRAY_CORE_PATH"; exit 1; }
[ -d "$ANDROID_NDK_HOME" ] || { echo "NDK not found at $ANDROID_NDK_HOME"; exit 1; }
[ -f "$KEYSTORE_PATH" ] || { echo "Keystore not found at $KEYSTORE_PATH"; exit 1; }

echo "=== v2rayNG ${VERSION} → ${TARGET_REPO} ==="

# 1. Bump version in app/build.gradle.kts (auto-increment versionCode)
GRADLE_FILE="V2rayNG/app/build.gradle.kts"
CUR_CODE=$(grep -E "^[[:space:]]*versionCode = " "$GRADLE_FILE" | head -1 | sed -E 's/.*versionCode = ([0-9]+).*/\1/')
NEW_CODE=$((CUR_CODE + 1))
sed -i -E "s|versionCode = [0-9]+|versionCode = ${NEW_CODE}|" "$GRADLE_FILE"
sed -i -E "s|versionName = \".*\"|versionName = \"${VERSION}\"|" "$GRADLE_FILE"
echo "  versionCode ${CUR_CODE} → ${NEW_CODE}, versionName → ${VERSION}"

# 2. Initialize submodules
echo ""
echo ">>> Initializing submodules..."
git submodule update --init --recursive

# 3. Patch AndroidLibXrayLite go.mod with a local replace pointing at the Xray-core fork.
#    Each run strips any prior replace and re-appends it, so reruns stay clean.
echo ""
echo ">>> Pointing AndroidLibXrayLite at ${XRAY_CORE_PATH}..."
pushd AndroidLibXrayLite >/dev/null
sed -i "/^replace github\.com\/xtls\/xray-core =>/d" go.mod
printf "\nreplace github.com/xtls/xray-core => %s\n" "$XRAY_CORE_PATH" >> go.mod
go mod tidy

# 4. Geo data baked into libv2ray.aar
echo ""
echo ">>> Downloading geo assets..."
mkdir -p assets data
curl -sL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o data/geoip.dat
curl -sL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o data/geosite.dat
curl -sL https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip-only-cn-private.dat -o data/geoip-only-cn-private.dat
cp data/*.dat assets/

# 5. gomobile
if ! command -v gomobile >/dev/null; then
  echo ""
  echo ">>> Installing gomobile..."
  go install golang.org/x/mobile/cmd/gomobile@latest
fi
gomobile init >/dev/null 2>&1 || true

# 6. libv2ray.aar
echo ""
echo ">>> Building libv2ray.aar..."
gomobile bind -v -androidapi 24 -trimpath -ldflags='-s -w -buildid=' ./
popd >/dev/null

mkdir -p V2rayNG/app/libs
cp AndroidLibXrayLite/libv2ray.aar V2rayNG/app/libs/
echo "  Copied $(ls -lh V2rayNG/app/libs/libv2ray.aar | awk '{print $5}') libv2ray.aar"

# 7. libhev-socks5-tunnel.so
echo ""
echo ">>> Building libhev-socks5-tunnel..."
rm -rf libs
bash compile-hevtun.sh >/dev/null
cp -r libs/* V2rayNG/app/libs/

# 8. Signed APKs
echo ""
echo ">>> Building signed APKs..."
pushd V2rayNG >/dev/null
echo "sdk.dir=${ANDROID_HOME}" > local.properties
chmod 755 gradlew
./gradlew clean assembleRelease -x licenseFdroidReleaseReport \
  -Pandroid.injected.signing.store.file="$KEYSTORE_PATH" \
  -Pandroid.injected.signing.store.password="$KEYSTORE_PASSWORD" \
  -Pandroid.injected.signing.key.alias="$KEY_ALIAS" \
  -Pandroid.injected.signing.key.password="$KEY_PASSWORD"
popd >/dev/null

APK_PLAY="V2rayNG/app/build/outputs/apk/playstore/release"
APK_FDROID="V2rayNG/app/build/outputs/apk/fdroid/release"
echo ""
echo "Built APKs:"
ls -lh "$APK_PLAY"/*.apk "$APK_FDROID"/*.apk | awk '{print "  " $9 "  " $5}'

# 9. Release
echo ""
echo ">>> Creating release ${VERSION} on ${TARGET_REPO}..."
gh release create "$VERSION" -R "$TARGET_REPO" \
  "$APK_PLAY"/*.apk "$APK_FDROID"/*.apk \
  --title "$VERSION" \
  --prerelease \
  --notes "Fedarisha v2rayNG fork. libv2ray.aar built from ${XRAY_CORE_PATH}."

echo ""
echo "=== Done ==="
echo "  Release: https://github.com/${TARGET_REPO}/releases/tag/${VERSION}"
echo ""
echo "Commit the version bump when you're ready:"
echo "  git add ${GRADLE_FILE} && git commit -m 'Release ${VERSION}' && git tag ${VERSION} && git push --follow-tags"
