import XCTest
@testable import SickPLSMonitorKit

final class WorkspaceLayoutTests: XCTestCase {
    func testAllChannelCountsVisibilityModesAndTabsPreserveFieldAndAccountForMixer() {
        for count in 0...8 { for width in stride(from: 680, through: 2560, by: 20) { for mask in 0..<16 {
            let visibility = WorkspaceLayout.Visibility(setup: mask & 1 != 0, layers: mask & 2 != 0, cell: mask & 4 != 0, channelStrip: mask & 8 != 0)
            for mode in [WorkspaceLayout.Mode.edit, .perform] { for tab in [WorkspaceLayout.InspectorTab.layers, .cell] {
                let layout = WorkspaceLayout.forAvailableWidth(Double(width), visibility: visibility, mode: mode, selectedTab: tab, channelCount: count)
                XCTAssertGreaterThanOrEqual(layout[.field].width, 520)
                for (rowIndex, row) in layout.rows.enumerated() {
                    var x = 0.0
                    for area in row.areas {
                        XCTAssertEqual(layout[area].row, rowIndex)
                        XCTAssertEqual(layout[area].x, x)
                        x += layout[area].width
                    }
                    XCTAssertEqual(x + row.trailingSpace, Double(width))
                    XCTAssertGreaterThanOrEqual(row.trailingSpace, 0)
                }
                if mode == .edit && visibility.channelStrip {
                    let fullMixer = Double(count + 1) * 72
                    XCTAssertGreaterThanOrEqual(layout[.channelStrip].width, 72)
                    XCTAssertLessThanOrEqual(layout[.channelStrip].width, fullMixer)
                    let secondary = [WorkspaceLayout.Area.setup, .layers, .cell].reduce(0.0) { $0 + layout[$1].width }
                    let expected = layout.arrangement == .stacked ? min(fullMixer, max(72, Double(width) - secondary)) : fullMixer
                    XCTAssertEqual(layout[.channelStrip].width, expected)
                }
            } }
        } } }
    }
    func testNarrowEightChannelMixerStaysAtRightAndScrollsInsteadOfWrappingBelow() {
        for (width, mixerWidth) in [(900.0, 300.0), (680.0, 80.0)] {
            let layout = WorkspaceLayout.forAvailableWidth(width, channelCount: 8)
            XCTAssertEqual(layout.arrangement, .stacked)
            XCTAssertEqual(layout.rows.count, 2)
            XCTAssertEqual(layout[.channelStrip].row, 1)
            XCTAssertEqual(layout[.channelStrip].x, 600)
            XCTAssertEqual(layout[.channelStrip].width, mixerWidth)
            XCTAssertEqual(layout[.field].width, width)
        }
    }
    func testEveryWidthVisibilityModeAndTabAccountsForEverySlot() {
        for width in 900...2560 {
            for mask in 0..<16 {
                let wishes = WorkspaceLayout.Visibility(setup: mask & 1 != 0,
                    layers: mask & 2 != 0, cell: mask & 4 != 0, channelStrip: mask & 8 != 0)
                for mode in [WorkspaceLayout.Mode.edit, .perform] {
                    for tab in [WorkspaceLayout.InspectorTab.layers, .cell] {
                        let layout = WorkspaceLayout.forAvailableWidth(Double(width), visibility: wishes, mode: mode, selectedTab: tab)
                        XCTAssertTrue(layout[.field].visible)
                        XCTAssertGreaterThanOrEqual(layout[.field].width, WorkspaceLayout.centerMinimumWidth)
                        XCTAssertEqual(layout.mode, mode)
                        var seen: Set<WorkspaceLayout.Area> = []
                        for (index, row) in layout.rows.enumerated() {
                            var x = 0.0
                            for area in row.areas {
                                let region = layout[area]
                                XCTAssertTrue(seen.insert(area).inserted)
                                XCTAssertTrue(region.visible)
                                XCTAssertTrue(mode == .perform ? area == .field || area == .channelStrip : wishes[area])
                                XCTAssertEqual(region.row, index)
                                XCTAssertEqual(region.x, x, accuracy: 1e-9)
                                XCTAssertGreaterThan(region.width, 0)
                                x += region.width
                                XCTAssertLessThanOrEqual(x, Double(width))
                            }
                            XCTAssertGreaterThanOrEqual(row.trailingSpace, 0)
                            XCTAssertEqual(x + row.trailingSpace, Double(width), accuracy: 1e-9)
                        }
                        for area in WorkspaceLayout.Area.allCases {
                            let inactiveTab = layout.usesInspectorTabs &&
                                (area == .layers && tab == .cell || area == .cell && tab == .layers)
                            XCTAssertEqual(layout[area].visible, mode == .perform ? area == .field || area == .channelStrip : wishes[area] && !inactiveTab)
                            if !layout[area].visible { XCTAssertEqual(layout[area].width, 0) }
                        }
                    }
                }
            }
        }
    }
    func testExactBoundariesSwitchToTabsThenStackWithoutSqueezingField() {
        let wide = WorkspaceLayout.forAvailableWidth(1728)
        XCTAssertEqual(wide.arrangement, .sideBySide)
        XCTAssertEqual(wide[.field].width, 764)
        XCTAssertEqual(wide[.setup].width, 300)
        XCTAssertEqual(wide[.layers].width, 300)
        XCTAssertEqual(wide[.cell].width, 220)
        XCTAssertEqual(wide[.channelStrip].width, 144)
        XCTAssertEqual(WorkspaceLayout.forAvailableWidth(1484).arrangement, .sideBySide)
        XCTAssertEqual(WorkspaceLayout.forAvailableWidth(1483).arrangement, .tabs)
        let tabs = WorkspaceLayout.forAvailableWidth(1280, selectedTab: .cell)
        XCTAssertEqual(tabs.arrangement, .tabs)
        XCTAssertEqual(tabs[.field].width, 536)
        XCTAssertFalse(tabs[.layers].visible)
        XCTAssertEqual(tabs[.cell].width, 300)
        XCTAssertEqual(WorkspaceLayout.forAvailableWidth(1264)[.field].width, 520)
        let stacked = WorkspaceLayout.forAvailableWidth(1263)
        XCTAssertEqual(stacked.arrangement, .stacked)
        XCTAssertEqual(stacked[.field].width, 1263)
        XCTAssertEqual(stacked.rows.count, 2)
        XCTAssertEqual(WorkspaceLayout.forAvailableWidth(1024).arrangement, .stacked)
        let playing = WorkspaceLayout.forAvailableWidth(900, visibility: .init(setup: false, layers: false, cell: false))
        XCTAssertEqual(playing.arrangement, .sideBySide)
        XCTAssertEqual(playing[.field].width, 756)
    }
    func testHiddenAreasReturnAllSpaceToTheFieldAndInvalidWidthsAreTotal() {
        let field = WorkspaceLayout.forAvailableWidth(900, visibility: .init(setup: false, layers: false, cell: false, channelStrip: false))
        XCTAssertEqual(field[.field].width, 900)
        for width in [Double.nan, .infinity, -.infinity, -1, 0, 519, 520, 680] {
            let layout = WorkspaceLayout.forAvailableWidth(width)
            XCTAssertGreaterThanOrEqual(layout[.field].width, 520)
            for row in layout.rows {
                XCTAssertGreaterThanOrEqual(row.trailingSpace, 0)
            }
        }
    }
}
