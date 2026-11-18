#!/bin/bash
#
# Baut SickPLSMonitor als echte macOS-App (SICK-032a2).
#
# WARUM DAS NÖTIG IST
#
# `swift build` erzeugt eine nackte ausführbare Datei. Startet man die
# direkt aus dem Terminal, behandelt macOS sie nicht als reguläre App:
# Sie bekommt keinen Eintrag im Dock, lässt sich nicht normal nach vorn
# holen, Textfelder bekommen keinen Tastaturfokus, und die native
# Vollbildfunktion fehlt. Das ist kein Fehler im Programm, sondern die
# Folge des fehlenden Bundles — LaunchServices entscheidet anhand von
# `Info.plist`, was eine App ist.
#
# Der rohe SwiftPM-Start ist deshalb ausdrücklich KEIN Endnutzerweg.
# Dieses Skript erzeugt das Bundle, das einer ist.
#
# BENUTZUNG
#
#   scripts/make-app-bundle.sh            # Release, danach im Finder öffnen
#   scripts/make-app-bundle.sh debug      # Debug-Build
#   scripts/make-app-bundle.sh release run   # bauen und sofort starten
#
#   scripts/make-app-bundle.sh release --universal  # arm64 + Intel, macOS 12
#   SICK_TEST_ARTIFACT_DIR=/tmp/planarium scripts/make-app-bundle.sh debug --universal
#
# Das Ergebnis liegt unter .build/bundle/SickPLSMonitor.app
#
# Die Alltagssignierung bevorzugt eine stabile Apple-Development-Identität.
# Falls auf dem Rechner keine vorhanden ist, fällt das Skript mit deutlicher
# Meldung auf ad-hoc zurück. Hardened Runtime bleibt bewusst aus: PACE/UAD-
# Plug-ins benötigen den bisherigen Signierungsmodus.

set -euo pipefail

CONFIGURATION=release
ACTION=""
UNIVERSAL=0
for argument in "$@"; do
    case "$argument" in
        release|debug) CONFIGURATION="$argument" ;;
        run) ACTION=run ;;
        --universal) UNIVERSAL=1 ;;
        *) echo "Unbekanntes Argument: $argument" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BUNDLE_ROOT="${SICK_TEST_ARTIFACT_DIR:-$ROOT/.build}/bundle"
APP="$BUNDLE_ROOT/SickPLSMonitor.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "==> Baue SickPLSMonitor ($CONFIGURATION)"
if [ "$UNIVERSAL" -eq 1 ]; then
    mkdir -p "$BUNDLE_ROOT"
    UNIVERSAL_TEMP="$(mktemp -d "$BUNDLE_ROOT/universal.XXXXXX")"
    trap 'rm -rf "$UNIVERSAL_TEMP"' EXIT
    UNIVERSAL_SCRATCH="${SICK_TEST_ARTIFACT_DIR:-$ROOT/.build}/universal"
    for architecture in arm64 x86_64; do
        triple="$architecture-apple-macosx12.0"
        scratch="$UNIVERSAL_SCRATCH/$architecture"
        swift build -c "$CONFIGURATION" --product SickPLSMonitor --triple "$triple" --scratch-path "$scratch"
        bin_dir="$(swift build -c "$CONFIGURATION" --triple "$triple" --scratch-path "$scratch" --show-bin-path)"
        lipo -verify_arch "$architecture" "$bin_dir/SickPLSMonitor"
        cp "$bin_dir/SickPLSMonitor" "$UNIVERSAL_TEMP/$architecture"
        if [ "$architecture" = arm64 ]; then
            cp -R "$bin_dir/SickPLSCore_PlanariumPresets.bundle" "$UNIVERSAL_TEMP/"
        fi
    done
    lipo -create "$UNIVERSAL_TEMP/arm64" "$UNIVERSAL_TEMP/x86_64" -output "$UNIVERSAL_TEMP/SickPLSMonitor"
    for architecture in arm64 x86_64; do
        lipo -verify_arch "$architecture" "$UNIVERSAL_TEMP/SickPLSMonitor"
    done
    BINARY="$UNIVERSAL_TEMP/SickPLSMonitor"
else
    swift build -c "$CONFIGURATION" --product SickPLSMonitor
    BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/SickPLSMonitor"
fi

BUILD_NUMBER="unbekannt"
GIT_REVISION="unbekannt"
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || printf 'unbekannt')"
    GIT_REVISION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unbekannt')"
    if [ "$GIT_REVISION" != "unbekannt" ] && [ -n "$(git -C "$ROOT" status --porcelain -- Sources Package.swift)" ]; then
        GIT_REVISION="${GIT_REVISION}+local"
    fi
else
    echo "    Git nicht verfügbar — Bundle-Stand wird als unbekannt markiert."
fi

if [ ! -x "$BINARY" ]; then
    echo "Erwartete ausführbare Datei nicht gefunden: $BINARY" >&2
    exit 1
fi

echo "==> Baue Bundle zusammen"
rm -rf "$APP"
mkdir -p "$MACOS_DIR"
cp "$BINARY" "$MACOS_DIR/SickPLSMonitor"
mkdir -p "$CONTENTS/Resources"
cp "$(dirname "$0")/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# SwiftPM locates the preset bundle inside the application's Resources.
# Ship it explicitly: the executable alone has no factory preset files.
PRESET_RESOURCES="$(dirname "$BINARY")/SickPLSCore_PlanariumPresets.bundle"
if [ ! -d "$PRESET_RESOURCES" ]; then
    echo "Preset-Ressourcenbundle fehlt im Build." >&2
    exit 1
fi
cp -R "$PRESET_RESOURCES" "$CONTENTS/Resources/"

# `LSMinimumSystemVersion` hält die macOS-12-Zusage des Projekts auch im
# Bundle fest. `LSUIElement` fehlt absichtlich: Nur ohne diesen Schlüssel
# ist die App eine reguläre Vordergrund-App mit Dock-Eintrag, Menüleiste,
# Tastaturfokus und Vollbild.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Planarium</string>
    <key>CFBundleDisplayName</key>
    <string>Planarium</string>
    <key>CFBundleExecutable</key>
    <string>SickPLSMonitor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>de.sick.pls.monitor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>PlanariumGitRevision</key>
    <string>${GIT_REVISION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Planarium receives simulated scanner data from the iPhone app on the same local network.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Loaded audio plug-ins read their presets from the Documents folder.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_planarium-sim._tcp</string>
    </array>
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

SIGNING_IDENTITY="${PLANARIUM_SIGN_IDENTITY:-}"
SIGNED=0
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Signiere mit vorgegebener stabiler Identität: $SIGNING_IDENTITY"
    if codesign --force --sign "$SIGNING_IDENTITY" "$APP" >/dev/null 2>&1; then
        SIGNED=1
    else
        echo "    Vorgegebene Identität konnte nicht signieren."
    fi
else
    while IFS=$'\t' read -r candidate_hash candidate_name; do
        [ -z "$candidate_hash" ] && continue
        echo "==> Versuche Apple-Development-Identität: $candidate_name ($candidate_hash)"
        if codesign --force --sign "$candidate_hash" "$APP" >/dev/null 2>&1; then
            SIGNED=1
            break
        fi
    done < <(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Apple Development: / {
            hash = $2
            name = $0
            sub(/^[[:space:]]*[0-9]+\) [A-Fa-f0-9]+ "/, "", name)
            sub(/"[[:space:]]*$/, "", name)
            print hash "\t" name
        }')
fi

if [ "$SIGNED" -eq 0 ]; then
    echo "==> Keine verwendbare Apple-Development-Identität — signiere ad-hoc."
    codesign --force --sign - "$APP" >/dev/null 2>&1 || {
        echo "    (Ad-hoc-Signierung nicht möglich — die App startet trotzdem.)"
    }
fi

# Damit LaunchServices das frische Bundle sofort kennt.
if [ -z "${SICK_TEST_ARTIFACT_DIR:-}" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$APP" >/dev/null 2>&1 || true
fi

echo "==> Fertig: $APP"

if [ "$ACTION" = "run" ]; then
    echo "==> Starte"
    open "$APP"
fi
