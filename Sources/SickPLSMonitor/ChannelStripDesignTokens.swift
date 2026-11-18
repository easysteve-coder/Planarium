import SwiftUI
import SickPLSMonitorKit

/// Die SwiftUI-Seite der Kanalzug-Tokens (SICK-033a-0, SICK-033c).
///
/// **Hier steht keine eigene Zahl.** Jede Farbe, jedes Maß und jede
/// Schriftgröße kommt aus `ChannelStripLayout` in `SickPLSMonitorKit`,
/// wo sie ohne gerenderte Ansicht geprüft wird. Diese Datei übersetzt
/// nur in `Color`/`Font`/`CGFloat`.
enum ChannelStripDesignTokens {
    static let stripWidth = CGFloat(ChannelStripLayout.stripWidth)
    static let inspectorWidth = CGFloat(ChannelStripLayout.inspectorWidth)
    static let sidePanelSpacing = CGFloat(ChannelStripLayout.sidePanelSpacing)
    static let rowHitHeight = CGFloat(ChannelStripLayout.rowHitHeight)
    static let minimumHitTarget = CGFloat(ChannelStripLayout.minimumHitTarget)
    static let rowSpacing = CGFloat(ChannelStripLayout.rowSpacing)
    static let inset = CGFloat(ChannelStripLayout.inset)
    static let cardHeight = CGFloat(ChannelStripLayout.cardHeight)
    static let cornerRadius = CGFloat(ChannelStripLayout.cornerRadius)

    static let rowFont = Font.system(size: ChannelStripLayout.rowFontSize, design: .monospaced)
    static let microFont = Font.system(size: ChannelStripLayout.microFontSize, design: .monospaced)

    static let panelBackground = color(ChannelStripLayout.panelBackground)
    static let rowBackground = color(ChannelStripLayout.rowBackground)
    static let rowSelectedBackground = color(ChannelStripLayout.rowSelectedBackground)
    static let primaryText = color(ChannelStripLayout.primaryText)
    static let secondaryText = color(ChannelStripLayout.secondaryText)
    static let accent = color(ChannelStripLayout.accent)
    static let activeIndicator = color(ChannelStripLayout.activeIndicator)
    static let inactiveIndicator = color(ChannelStripLayout.inactiveIndicator)
    static let warning = color(ChannelStripLayout.warning)

    private static func color(_ value: StripColor) -> Color {
        Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }
}
