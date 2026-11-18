#!/bin/bash
#
# Baut SickPLSSetup als echte macOS-App (SICK-032a2, gleiches Muster wie
# scripts/make-app-bundle.sh für den Monitor).
#
# WARUM DAS NÖTIG IST
#
# `swift build` erzeugt eine nackte ausführbare Datei. Startet man die
# direkt aus dem Terminal (`.build/debug/SickPLSSetup`), behandelt macOS
# sie nicht als reguläre App: Sie bekommt keinen Eintrag im Dock, lässt
# sich nicht normal nach vorn holen, Textfelder bekommen keinen
# Tastaturfokus, und die native Vollbildfunktion fehlt. Das ist kein
# Fehler im Programm, sondern die Folge des fehlenden Bundles —
# LaunchServices entscheidet anhand von `Info.plist`, was eine App ist.
#
# Der rohe SwiftPM-Start ist deshalb ausdrücklich KEIN Endnutzerweg.
# Dieses Skript erzeugt das Bundle, das einer ist.
#
# BENUTZUNG
#
#   scripts/make-setup-app-bundle.sh              # Release, danach im Finder öffnen
#   scripts/make-setup-app-bundle.sh debug        # Debug-Build
#   scripts/make-setup-app-bundle.sh release run  # bauen und sofort starten
#
# Das Ergebnis liegt unter .build/bundle/SickPLSSetup.app
#
# NICHT ENTHALTEN, bewusst: Code-Signierung mit einer echten Identität,
# Notarisierung und Verteilung. Signiert wird ad-hoc, damit die App auf
# diesem Rechner stabil startet.

set -euo pipefail

CONFIGURATION="${1:-release}"
ACTION="${2:-}"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BUNDLE_ROOT="$ROOT/.build/bundle"
APP="$BUNDLE_ROOT/SickPLSSetup.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "==> Baue SickPLSSetup ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product SickPLSSetup

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/SickPLSSetup"
if [ ! -x "$BINARY" ]; then
    echo "Erwartete ausführbare Datei nicht gefunden: $BINARY" >&2
    exit 1
fi

echo "==> Baue Bundle zusammen"
rm -rf "$APP"
mkdir -p "$MACOS_DIR"
cp "$BINARY" "$MACOS_DIR/SickPLSSetup"

# `LSMinimumSystemVersion` hält die macOS-12-Zusage des Projekts auch im
# Bundle fest. `LSUIElement` fehlt absichtlich: Nur ohne diesen Schlüssel
# ist die App eine reguläre Vordergrund-App mit Dock-Eintrag, Menüleiste,
# Tastaturfokus und Vollbild.
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SICK PLS Setup</string>
    <key>CFBundleDisplayName</key>
    <string>SICK PLS Setup</string>
    <key>CFBundleExecutable</key>
    <string>SickPLSSetup</string>
    <key>CFBundleIdentifier</key>
    <string>de.sick.pls.setup</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Signiere ad-hoc"
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
    echo "    (Ad-hoc-Signierung nicht möglich — die App startet trotzdem.)"
}

# Damit LaunchServices das frische Bundle sofort kennt.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "==> Fertig: $APP"

if [ "$ACTION" = "run" ]; then
    echo "==> Starte"
    open "$APP"
fi
