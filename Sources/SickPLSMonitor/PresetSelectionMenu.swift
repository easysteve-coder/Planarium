import AppKit
import PlanariumDomain
import PlanariumPresets

final class PresetMenuTarget: NSObject {
    let chooseName: (String) -> Void
    init(_ chooseName: @escaping (String) -> Void) { self.chooseName = chooseName }
    @objc func choose(_ sender: NSMenuItem) { chooseName(sender.title) }
}

/// AppKit's actual menu tooltip, including before a preset is loaded.
/// SwiftUI picker-row help does not provide a reliable native menu tooltip.
enum PresetSelectionMenu {
    static func make(names: [String], summaries: [String: String], selected: String?, target: PresetMenuTarget) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(PresetMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = target; item.state = name == selected ? .on : .off
            let tooltip = PresetSummaryPresentation(summaries[name] ?? "").tooltip
            item.toolTip = tooltip.isEmpty ? nil : tooltip
            menu.addItem(item)
        }
        return menu
    }
}
