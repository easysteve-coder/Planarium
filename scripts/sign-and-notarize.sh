#!/bin/bash
#
# Signiert und notarisiert das App-Bundle aus `make-app-bundle.sh`
# (SICK-039). **Ownerschritt:** braucht eine Developer-ID-Identität im
# Schlüsselbund und ein `notarytool`-Profil. Ohne beides bricht das
# Skript ab -- es rät keine Identität und legt keine Zugangsdaten an.
#
# BENUTZUNG
#
#   SICK_SIGNING_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
#   SICK_NOTARY_PROFILE="<notarytool-Profilname>" \
#   scripts/sign-and-notarize.sh
#
# Das Profil wird einmalig vom Owner angelegt (App-spezifisches Passwort
# der Apple-ID, nie im Repo):
#
#   xcrun notarytool store-credentials "<Profilname>" \
#       --apple-id "<Apple-ID>" --team-id "<TEAMID>"
#
# Ergebnis: `.build/bundle/SickPLSMonitor.app` signiert, mit Hardened
# Runtime, notarisiert und geheftet; daneben `SickPLSMonitor.zip` für die
# Weitergabe. Nichts davon wird verschickt.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SICK_SIGNING_IDENTITY:-}"
PROFILE="${SICK_NOTARY_PROFILE:-}"
APP=".build/bundle/SickPLSMonitor.app"
ENTITLEMENTS="scripts/SickPLSMonitor.entitlements"
ZIP=".build/bundle/SickPLSMonitor.zip"

if [ -z "$IDENTITY" ] || [ -z "$PROFILE" ]; then
    echo "SICK_SIGNING_IDENTITY und SICK_NOTARY_PROFILE müssen gesetzt sein (Ownerschritt)." >&2
    exit 2
fi
if [ ! -d "$APP" ]; then
    echo "Bundle fehlt: erst scripts/make-app-bundle.sh ausführen." >&2
    exit 2
fi
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Identität nicht im Schlüsselbund: $IDENTITY" >&2
    exit 2
fi

echo "==> Signiere mit Hardened Runtime"
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Verpacke für die Notarisierung"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Reiche bei Apple ein und warte"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Hefte das Ticket an"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Fertig: $APP (geheftet), $ZIP"
