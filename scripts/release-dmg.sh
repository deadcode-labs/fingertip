#!/bin/sh
#
# Compila Fingertip.app firmada con Developer ID, la notariza y la empaqueta
# en un DMG también notarizado. Para distribución directa (no App Store: la
# app no puede estar sandboxed, ver CLAUDE.md).
#
# Requiere una sola vez:
#   xcrun notarytool store-credentials fingertip-notary \
#     --apple-id <tu Apple ID> --team-id AAL663Y363 --password <app-specific password>
# (la contraseña se genera en appleid.apple.com → Seguridad → Contraseñas de apps)
#
# Sparkle signs the DMG with the EdDSA key stored in the login Keychain under
# the account "fingertip" (its public half is SUPublicEDKey in App/Info.plist).
# Back it up with:
#   build/release-dmg/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account fingertip -x fingertip-sparkle.key

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="AAL663Y363"
SIGN_IDENTITY="Developer ID Application: Maximiliano Ward (${TEAM_ID})"
NOTARY_PROFILE="fingertip-notary"
SPARKLE_ACCOUNT="fingertip"

BUILD_DIR="${REPO_ROOT}/build/release-dmg"
DIST_DIR="${REPO_ROOT}/dist"
ARCHIVE_PATH="${BUILD_DIR}/Fingertip.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
EXPORT_OPTIONS_PATH="${BUILD_DIR}/export-options.plist"
APP_PATH="${EXPORT_PATH}/Fingertip.app"
ZIP_PATH="${DIST_DIR}/Fingertip.zip"
DMG_PATH="${DIST_DIR}/Fingertip.dmg"
STAGING_DIR="${DIST_DIR}/staging"
PACKAGES_DIR="${BUILD_DIR}/SourcePackages"
SPARKLE_BIN="${PACKAGES_DIR}/artifacts/sparkle/Sparkle/bin"

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

echo "==> Archivando Fingertip.app (Release, Developer ID)"
xcodebuild archive \
  -project "${REPO_ROOT}/App/Fingertip.xcodeproj" \
  -scheme Fingertip \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -clonedSourcePackagesDirPath "${PACKAGES_DIR}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="${TEAM_ID}"

cat > "${EXPORT_OPTIONS_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "==> Exportando para distribución (archive sin get-task-allow, con timestamp seguro)"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PATH}"

echo "==> Verificando firma"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "==> Notarizando la app"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"
rm -f "${ZIP_PATH}"

echo "==> Armando el DMG"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create -volname "Fingertip" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${STAGING_DIR}"

echo "==> Firmando y notarizando el DMG"
codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"

echo "==> Verificando Gatekeeper"
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}"
spctl -a -vvv "${APP_PATH}"

# The feed is SUFeedURL = releases/latest/download/appcast.xml, so every
# release carries its own appcast next to the DMG it points at.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
echo "==> Firmando para Sparkle y generando el appcast (v${VERSION})"
"${SPARKLE_BIN}/generate_appcast" \
  --account "${SPARKLE_ACCOUNT}" \
  --download-url-prefix "https://github.com/deadcode-labs/fingertip/releases/download/v${VERSION}/" \
  -o "${DIST_DIR}/appcast.xml" \
  "${DIST_DIR}"

echo "==> Listo: ${DMG_PATH} y ${DIST_DIR}/appcast.xml"
echo "    Subí los dos al release v${VERSION}:"
echo "    gh release upload v${VERSION} \"${DMG_PATH}\" \"${DIST_DIR}/appcast.xml\""
