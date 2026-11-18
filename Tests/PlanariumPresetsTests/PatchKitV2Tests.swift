import Foundation
import XCTest
import PlanariumDomain
import PLSDeviceValues
@testable import PlanariumPresets

/// Patch Construction Kit v2: shapes, placement, play area, clipping, raster overlap and the SVG preview.
/// Expectations are measured on the polarDeviceV2 grid (ring = raw cm, bearing = -90° + 0.5°·tick)
/// with a small independent oracle, never by re-running the kit's own placement code.
final class PatchKitV2Tests: XCTestCase {
    private var directory: URL!
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var evidence: URL { repo.appendingPathComponent("Tests/PlanariumPresetsTests/Fixtures/EaglePatch") }
    private var examples: URL { repo.appendingPathComponent("PatchKit/examples") }
    private var v1Fixtures: URL { repo.appendingPathComponent("Tests/PlanariumPresetsTests/Fixtures/PatchKitV1") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PatchKitV2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: Fixtures

    private func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name); try data.write(to: url); return url
    }
    /// Catalog with the real measured Surge default (`surge.init`, instrument) and Eagle delay (effect).
    private var cachedCatalog: URL?
    private func makeCatalog() throws -> URL {
        if let cachedCatalog { return cachedCatalog }
        let catalog = directory.appendingPathComponent("catalog/sounds.json")
        _ = try SoundCatalog.importState(catalog: catalog, state: evidence.appendingPathComponent("surge-default-state.plist"),
                                         alias: "surge.init", role: .instrument, description: "demo")
        _ = try SoundCatalog.importState(catalog: catalog, state: evidence.appendingPathComponent("delay-eagle-state.plist"),
                                         alias: "apple.delay.eagle", role: .effect, description: "measured")
        cachedCatalog = catalog
        return catalog
    }
    private func compile(_ json: String) throws -> PatchBuild {
        try PatchCompiler.compile(try PatchKitRecipe.decode(Data(json.utf8)), catalog: try SoundCatalog.load(from: try makeCatalog()))
    }
    private func expectFailure(_ json: String, contains needles: String..., file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try compile(json)
            XCTFail("expected a refusal containing \(needles)", file: file, line: line)
        } catch let error as PatchKitError {
            for needle in needles {
                XCTAssertTrue(error.description.contains(needle), "“\(needle)” not in: \(error.description)", file: file, line: line)
            }
        } catch { XCTFail("unexpected error \(error)", file: file, line: line) }
    }

    private func rectArea(_ xMin: Int = -100, _ xMax: Int = 100, _ yMin: Int = 0, _ yMax: Int = 200) -> String {
        #"{"type":"rectangle","xMinCm":\#(xMin),"xMaxCm":\#(xMax),"yMinCm":\#(yMin),"yMaxCm":\#(yMax)}"#
    }
    private func region(_ id: String, shape: String, at: String? = nil, note: String = #""C4""#, channel: String = "ch", color: String = "#4CAF50") -> String {
        #"{"id":"\#(id)","shape":\#(shape),\#(at.map { "\"transform\":\($0)," } ?? "")"note":\#(note),"channel":"\#(channel)","color":"\#(color)"}"#
    }
    private func rect(_ w: Double, _ h: Double) -> String { #"{"type":"rectangle","widthCm":\#(w),"heightCm":\#(h)}"# }
    private func circle(_ r: Double) -> String { #"{"type":"circle","radiusCm":\#(r)}"# }
    private func polygon(_ points: [[Double]]) -> String {
        #"{"type":"polygon","pointsCm":[\#(points.map { "[\($0[0]),\($0[1])]" }.joined(separator: ","))]}"#
    }
    private func recipeV2(_ regions: [String], play: String? = nil, top: String = "") -> String {
        #"{"version":2,"name":"T2",\#(top)"channels":[{"id":"ch","instrument":"surge.init"},{"id":"b","instrument":"surge.init"}],"playArea":\#(play ?? rectArea()),"regions":[\#(regions.joined(separator: ","))]}"#
    }
    private func cells(_ build: PatchBuild, _ id: String) -> Set<PolarDeviceLattice> {
        Set(build.drawing.regions.first { $0.id == id }!.cells)
    }
    private func point(_ cell: PolarDeviceLattice) -> (x: Double, y: Double) {
        let bearing = (-90 + 0.5 * Double(cell.sector)) * Double.pi / 180
        return (Double(cell.ring) * sin(bearing), Double(cell.ring) * cos(bearing))
    }
    private func cell(_ ring: Int, _ tick: Int) -> PolarDeviceLattice { PolarDeviceLattice(ring: ring, sector: tick)! }

    // MARK: Oracle: world-space polygon test on forward-transformed corners

    private func forward(_ p: (Double, Double), x: Double, y: Double, degrees: Double, mirror: Bool) -> (Double, Double) {
        let mirrored = mirror ? (-p.0, p.1) : p
        let a = degrees * Double.pi / 180
        return (cos(a) * mirrored.0 - sin(a) * mirrored.1 + x, sin(a) * mirrored.0 + cos(a) * mirrored.1 + y)
    }
    private func insidePolygon(_ p: (Double, Double), _ corners: [(Double, Double)]) -> Bool {
        var inside = false, j = corners.count - 1
        for i in corners.indices {
            let a = corners[i], b = corners[j]
            if (a.1 > p.1) != (b.1 > p.1), p.0 < (b.0 - a.0) * (p.1 - a.1) / (b.1 - a.1) + a.0 { inside.toggle() }
            j = i
        }
        return inside
    }
    private func oracle(corners: [(Double, Double)]) -> Set<PolarDeviceLattice> {
        var result = Set<PolarDeviceLattice>()
        for ring in 1...400 { for tick in 0...360 {
            let cellPoint = point(cell(ring, tick))
            if insidePolygon(cellPoint, corners) { result.insert(cell(ring, tick)) }
        } }
        return result
    }

    // MARK: v1 stays byte-identical

    func testVersionOneOutputIsByteIdenticalToTheOutputSavedBeforeVersionTwo() throws {
        let demo = directory.appendingPathComponent("demo/sounds.json")
        _ = try SoundCatalog.importState(catalog: demo, state: evidence.appendingPathComponent("delay-eagle-state.plist"), alias: "apple.delay.eagle", role: .effect, description: "")
        _ = try SoundCatalog.importState(catalog: demo, state: evidence.appendingPathComponent("surge-default-state.plist"), alias: "surge.init", role: .instrument, description: "")
        let catalog = try SoundCatalog.load(from: demo)
        for name in ["simple-three-bands", "chord-ladder"] {
            let recipe = try PatchKitRecipe.decode(try read(examples.appendingPathComponent("\(name).recipe.json")))
            guard case .v1 = recipe else { return XCTFail("\(name) must stay a version 1 recipe") }
            XCTAssertEqual(try PatchCompiler.compile(recipe, catalog: catalog).data, try read(v1Fixtures.appendingPathComponent("\(name).sickpreset.json")), name)
        }
        // The Eagle preset that was verified against real captures, rebuilt from its recipe and real states.
        let eagle = directory.appendingPathComponent("eagle/sounds.json")
        _ = try SoundCatalog.importState(catalog: eagle, state: evidence.appendingPathComponent("surge-organ-eagle-state.plist"), alias: "surge.organ1", role: .instrument, description: "")
        _ = try SoundCatalog.importState(catalog: eagle, state: evidence.appendingPathComponent("delay-eagle-state.plist"), alias: "apple.delay.eagle", role: .effect, description: "")
        let recipe = try PatchKitRecipe.decode(try read(evidence.appendingPathComponent("eagle-blues.recipe.json")))
        let rebuilt = try PatchCompiler.compile(recipe, catalog: try SoundCatalog.load(from: eagle))
        XCTAssertEqual(rebuilt.data, try read(evidence.appendingPathComponent("Eagle Organ - A Blues.sickpreset.json")))
    }

    func testVersionsAreNeverMixed() {
        expectFailure(#"{"version":1,"name":"T","channels":[{"id":"ch","instrument":"surge.init"}],"playArea":\#(rectArea()),"regions":[]}"#,
                      contains: "unknown field \"playArea\"", "version 2")
        expectFailure(#"{"version":2,"name":"T","channels":[{"id":"ch","instrument":"surge.init"}],"playArea":\#(rectArea()),"bands":[]}"#,
                      contains: "bands belong to recipe version 1")
        expectFailure(recipeV2(["{\"id\":\"a\",\"fromCm\":40,\"toCm\":60,\"shape\":\(circle(5)),\"note\":\"C4\",\"channel\":\"ch\",\"color\":\"#4CAF50\"}"]),
                      contains: "distance bands are version 1")
        expectFailure(#"{"version":3,"name":"T","channels":[],"bands":[]}"#, contains: "unsupported recipe version 3", "versions 1 and 2")
        expectFailure(recipeV2([region("a", shape: circle(5))], top: #""mode":"arpeggio","#), contains: "unsupported mode")
        expectFailure(recipeV2([region("a", shape: circle(5))], top: #""outsidePolicy":"shrink","#), contains: "outsidePolicy \"shrink\" is unknown")
    }

    // MARK: Measured geometry: left, right, front, distance

    func testRectangleCircleAndSectorAnchorsOnTheMeasuringGrid() throws {
        // Rectangle x -80…-20 (width 60), y 0…20 centred at (-50, 10): lower edge included, upper excluded.
        let build = try compile(recipeV2([
            region("left", shape: rect(60, 20), at: #"{"xCm":-50,"yCm":10}"#, note: #""C4""#),
            region("front", shape: rect(20, 20), at: #"{"xCm":0,"yCm":60}"#, note: #""D4""#),
            region("ring", shape: circle(15), at: #"{"xCm":0,"yCm":150}"#, note: #""E4""#),
            region("right", shape: #"{"type":"sector","fromCm":50,"toCm":70,"fromDegrees":60,"toDegrees":90}"#, note: #""F4""#),
        ]))
        let left = cells(build, "left"), front = cells(build, "front"), ring = cells(build, "ring"), right = cells(build, "right")
        XCTAssertTrue(left.contains(cell(60, 0)), "(-60, 0) is left of the scanner, y = 0 lower edge included")
        XCTAssertFalse(left.contains(cell(60, 360)), "(+60, 0) is right of the scanner")
        XCTAssertFalse(left.contains(cell(81, 0)), "x = -81 lies beyond the left edge (-80)")
        XCTAssertTrue(left.contains(cell(80, 0)), "x = -80 is the included lower x edge")
        XCTAssertFalse(left.contains(cell(20, 0)), "x = -20 is the excluded upper x edge")
        XCTAssertTrue(left.contains(cell(21, 0)))
        XCTAssertTrue(front.contains(cell(50, 180)), "(0, 50): lower y edge included")
        XCTAssertTrue(front.contains(cell(69, 180)))
        XCTAssertFalse(front.contains(cell(70, 180)), "(0, 70): upper y edge excluded")
        XCTAssertFalse(front.contains(cell(49, 180)))
        XCTAssertTrue(ring.contains(cell(135, 180)) && ring.contains(cell(165, 180)), "circle border is inside: distance exactly 15 cm")
        XCTAssertFalse(ring.contains(cell(134, 180)) || ring.contains(cell(166, 180)))
        XCTAssertTrue(right.contains(cell(50, 360)), "ring sector from 50 included, +90° included as last end")
        XCTAssertFalse(right.contains(cell(70, 360)), "toCm is excluded")
        XCTAssertTrue(right.contains(cell(60, 300)) && !right.contains(cell(60, 299)), "bearing 60° is the first tick of the window (tick 300)")
        // Every cell of every region sits exactly on its ring: distance from the scanner is the ring in cm.
        for region in build.drawing.regions { for c in region.cells { XCTAssertEqual(hypot(point(c).x, point(c).y), Double(c.ring), accuracy: 1e-9) } }
    }

    func testRingSectorWindowsAreHalfOpenWithTheFullFanException() throws {
        let sector = { (from: Int, to: Int) in #"{"type":"sector","fromCm":40,"toCm":60,"fromDegrees":\#(from),"toDegrees":\#(to)}"# }
        let narrow = try compile(recipeV2([region("s", shape: sector(-30, 30))])), sectorCells = cells(narrow, "s")
        XCTAssertEqual(sectorCells.count, 20 * 120, "20 rings × ticks for -30°…<+30°")
        XCTAssertTrue(sectorCells.contains(cell(40, 120)) && !sectorCells.contains(cell(40, 119)), "-30° is tick 120 and included")
        XCTAssertTrue(sectorCells.contains(cell(59, 239)) && !sectorCells.contains(cell(59, 240)), "+30° is tick 240 and excluded")
        XCTAssertFalse(sectorCells.contains(cell(60, 180)), "radius 60 is excluded")
        let fan = cells(try compile(recipeV2([region("s", shape: sector(-90, 90))])), "s")
        XCTAssertEqual(fan.count, 20 * 361, "the whole front fan includes tick 360")
        let almost = cells(try compile(recipeV2([region("s", shape: sector(-90, 89))])), "s")
        XCTAssertEqual(almost.count, 20 * 358, "only +90° as the end limit is inclusive")
        expectFailure(recipeV2([region("s", shape: sector(30, -30))]), contains: "-90 <= fromDegrees < toDegrees <= 90")
        expectFailure(recipeV2([region("s", shape: sector(-90, 91))]), contains: "-90 <= fromDegrees < toDegrees <= 90")
        expectFailure(recipeV2([region("s", shape: #"{"type":"sector","fromCm":60,"toCm":40,"fromDegrees":-10,"toDegrees":10}"#)]), contains: "0 <= fromCm < toCm")
    }

    func testSectorShapeRefusesAPlacementButAcceptsExplicitDefaults() throws {
        let sector = #"{"type":"sector","fromCm":40,"toCm":60,"fromDegrees":-30,"toDegrees":30}"#
        for transform in [#"{"rotationDegrees":10}"#, #"{"xCm":5}"#, #"{"mirrorX":true}"#] {
            expectFailure(recipeV2([region("s", shape: sector, at: transform)]), contains: "cannot be moved, rotated or mirrored")
        }
        XCTAssertNoThrow(try compile(recipeV2([region("s", shape: sector, at: #"{"xCm":0,"yCm":0,"rotationDegrees":0,"mirrorX":false}"#)])))
    }

    // MARK: Rotation, mirror, translation (order and direction)

    func testRotationTurnsCounterClockwise() throws {
        // A long thin bar along local +x, turned by +45°, must lean up and to the right (x and y grow together).
        let build = try compile(recipeV2([region("bar", shape: rect(60, 8), at: #"{"xCm":0,"yCm":100,"rotationDegrees":45}"#)]))
        let points = cells(build, "bar").map(point)
        let covariance = points.map { ($0.x) * ($0.y - 100) }.reduce(0, +) / Double(points.count)
        XCTAssertGreaterThan(covariance, 50, "counter-clockwise: right end is higher")
        let clockwise = try compile(recipeV2([region("bar", shape: rect(60, 8), at: #"{"xCm":0,"yCm":100,"rotationDegrees":-45}"#)]))
        let negative = cells(clockwise, "bar").map(point).map { $0.x * ($0.y - 100) }.reduce(0, +)
        XCTAssertLessThan(negative, 0)
        // A quarter turn swaps width and height exactly (no rounding noise at the edges).
        let tall = cells(try compile(recipeV2([region("bar", shape: rect(40, 10), at: #"{"xCm":0,"yCm":100,"rotationDegrees":90}"#)])), "bar")
        XCTAssertTrue(tall.contains(cell(80, 180)) && !tall.contains(cell(120, 180)), "y 80 is the included lower edge, y 120 the excluded upper edge")
    }

    func testMirrorIsAppliedBeforeRotationAndTranslation() throws {
        // Right-angled triangle with its tip on local +x: (0,0) (30,0) (0,10).
        let triangle = polygon([[0, 0], [30, 0], [0, 10]])
        func centroid(_ transform: String) throws -> (x: Double, y: Double) {
            let points = cells(try compile(recipeV2([region("t", shape: triangle, at: transform)])), "t").map(point)
            return (points.map(\.x).reduce(0, +) / Double(points.count), points.map(\.y).reduce(0, +) / Double(points.count))
        }
        let plain = try centroid(#"{"xCm":0,"yCm":100}"#)
        let mirrored = try centroid(#"{"xCm":0,"yCm":100,"mirrorX":true}"#)
        XCTAssertGreaterThan(plain.x, 5); XCTAssertLessThan(mirrored.x, -5)
        // mirror, then rotate 90°: tip (30,0) → (-30,0) → (0,-30): points down. Rotate-then-mirror would point up.
        let both = try centroid(#"{"xCm":0,"yCm":100,"mirrorX":true,"rotationDegrees":90}"#)
        XCTAssertLessThan(both.y, 100 - 5, "mirror first, then rotation")
        let rotated = try centroid(#"{"xCm":0,"yCm":100,"rotationDegrees":90}"#)
        XCTAssertGreaterThan(rotated.y, 100 + 5)
    }

    func testEveryShapeMatchesAnIndependentWorldSpaceOracleUnderPlacement() throws {
        let transform = (x: -35.0, y: 90.0, degrees: 33.0)
        let l: [(Double, Double)] = [(0, 0), (50, 0), (50, 20), (20, 20), (20, 60), (0, 60)]
        let cases: [(name: String, shape: String, local: [(Double, Double)], mirror: Bool)] = [
            ("rect", rect(40, 24), [(-20, -12), (20, -12), (20, 12), (-20, 12)], false),
            ("poly", polygon(l.map { [$0.0, $0.1] }), l, false),
            ("mirrored", polygon(l.map { [$0.0, $0.1] }), l, true),
            ("reversed", polygon(l.reversed().map { [$0.0, $0.1] }), l.reversed(), false),
        ]
        for item in cases {
            let at = #"{"xCm":\#(transform.x),"yCm":\#(transform.y),"rotationDegrees":\#(transform.degrees),"mirrorX":\#(item.mirror)}"#
            let build = try compile(recipeV2([region("r", shape: item.shape, at: at)], play: rectArea(-300, 300, 0, 400)))
            let corners = item.local.map { forward($0, x: transform.x, y: transform.y, degrees: transform.degrees, mirror: item.mirror) }
            XCTAssertEqual(cells(build, "r"), oracle(corners: corners), item.name)
            XCTAssertGreaterThan(cells(build, "r").count, 500)
        }
        // Circle: translated centre, distance test on the world point.
        let round = try compile(recipeV2([region("c", shape: circle(22.5), at: #"{"xCm":-35,"yCm":90}"#)]))
        var expected = Set<PolarDeviceLattice>()
        for ring in 1...400 { for tick in 0...360 where hypot(point(cell(ring, tick)).x + 35, point(cell(ring, tick)).y - 90) <= 22.5 + 1e-9 { expected.insert(cell(ring, tick)) } }
        XCTAssertEqual(cells(round, "c"), expected)
        // Winding direction does not matter.
        let forwardCells = cells(try compile(recipeV2([region("r", shape: polygon(l.map { [$0.0, $0.1] }))])), "r")
        let backwardCells = cells(try compile(recipeV2([region("r", shape: polygon(l.reversed().map { [$0.0, $0.1] }))])), "r")
        XCTAssertEqual(forwardCells, backwardCells)
    }

    func testConcavePolygonKeepsItsNotchEmpty() throws {
        let corners: [(Double, Double)] = [(-30, 0), (30, 0), (30, 40), (10, 40), (10, 15), (-10, 15), (-10, 40), (-30, 40)]
        let build = try compile(recipeV2([region("u", shape: polygon(corners.map { [$0.0, $0.1] }), at: #"{"xCm":0,"yCm":60}"#)]))
        let u = cells(build, "u")
        XCTAssertTrue(u.contains(cell(70, 180)), "(0, 70) is in the foot of the U")
        XCTAssertFalse(u.contains(cell(90, 180)), "(0, 90) is in the notch")
        let expected = oracle(corners: corners.map { ($0.0, $0.1 + 60) })
        // The oracle's even-odd rule leaves out a point exactly on an edge; the kit includes the border: (0, 75) lies on the notch floor.
        XCTAssertEqual(u.subtracting(expected), [cell(75, 180)], "the only difference is the border cell on the notch floor")
        XCTAssertEqual(expected.subtracting(u).map { "\($0.ring)/\($0.sector)" }.sorted(), [], "cells the oracle has but the kit has not")
    }

    // MARK: Polygon validity

    func testInvalidPolygonsAreRefusedWithAClearReason() {
        func bad(_ points: [[Double]], _ needle: String, line: UInt = #line) {
            expectFailure(recipeV2([region("p", shape: polygon(points), at: #"{"yCm":60}"#)]), contains: needle, line: line)
        }
        bad([[0, 0], [10, 0]], "needs 3–32 corner points, found 2")
        bad([[0, 0], [10, 0], [20, 0]], "no area")
        bad([[0, 0], [20, 20], [20, 0], [0, 20]], "cross or touch")                         // bow-tie
        bad([[0, 0], [20, 0], [20, 20], [0, 0]], "repeats an earlier point")               // repeated closing point
        bad([[0, 0], [20, 0], [20, 20], [10, 10], [10, 0], [0, 20]], "cross or touch")     // edge crossing
        bad([[0, 0], [20, 0], [10, 0], [10, 20]], "fold back")                             // overlaid edge
        bad([[0, 0], [10, 0], [10, 10], [5, 0], [0, 10]], "cross or touch")                // vertex on another edge
        expectFailure(recipeV2([region("p", shape: polygon((0..<33).map { [Double($0), Double($0 * $0 % 17)] }))]), contains: "needs 3–32 corner points, found 33")
        expectFailure(recipeV2([region("p", shape: #"{"type":"polygon","pointsCm":[[0,0],[1],[2,3]]}"#)]), contains: "[x, y]")
        expectFailure(recipeV2([region("p", shape: polygon([[0, 0], [5000, 0], [0, 10]]))]), contains: "within ±2000 cm")
    }

    func testPolygonAcceptsExactlyThirtyTwoPointsAndBothWindings() throws {
        var points: [[Double]] = []
        for index in 0..<32 {
            let angle = Double(index) * .pi / 16
            points.append([(20 * cos(angle) * 1000).rounded() / 1000, (20 * sin(angle) * 1000).rounded() / 1000])
        }
        for list in [points, points.reversed()] {
            let build = try compile(recipeV2([region("p", shape: polygon(list), at: #"{"yCm":80}"#)]))
            XCTAssertGreaterThan(cells(build, "p").count, 800)
        }
    }

    // MARK: Parameter ranges and unknown fields

    func testSizesPlayAreaAndFieldsAreValidatedStrictly() {
        expectFailure(recipeV2([region("a", shape: rect(0, 10))]), contains: "widthCm must be a finite number above 0")
        expectFailure(recipeV2([region("a", shape: rect(-5, 10))]), contains: "widthCm must be")
        expectFailure(recipeV2([region("a", shape: circle(0))]), contains: "radiusCm must be")
        expectFailure(recipeV2([region("a", shape: circle(3000))]), contains: "radiusCm must be")
        expectFailure(recipeV2([region("a", shape: circle(5), at: #"{"xCm":5000}"#)]), contains: "within ±2000 cm")
        expectFailure(recipeV2([region("a", shape: circle(5), at: #"{"rotationDegrees":400}"#)]), contains: "-360…360")
        expectFailure(recipeV2([region("a", shape: circle(5), at: #"{"turn":5}"#)]), contains: "unknown field \"turn\"")
        expectFailure(recipeV2([region("a", shape: #"{"type":"circle","radiusCm":5,"width":3}"#)]), contains: "unknown field \"width\"")
        expectFailure(recipeV2([region("a", shape: #"{"type":"star"}"#)]), contains: "shape.type \"star\" is unknown")
        expectFailure(recipeV2([region("a", shape: circle(5))], play: #"{"type":"rectangle","xMinCm":10,"xMaxCm":-10,"yMinCm":0,"yMaxCm":50}"#), contains: "xMinCm < xMaxCm")
        expectFailure(recipeV2([region("a", shape: circle(5))], play: rectArea(-10, 10, -5, 50)), contains: "behind the scanner")
        expectFailure(recipeV2([region("a", shape: circle(5))], play: #"{"type":"sector","fromCm":0,"toCm":50,"fromDegrees":-100,"toDegrees":20}"#), contains: "-90 <= fromDegrees")
        expectFailure(recipeV2([region("a", shape: circle(5))], play: #"{"type":"disc"}"#), contains: "playArea.type \"disc\" is unknown")
        expectFailure(recipeV2([region("a", shape: circle(5)), region("a", shape: circle(5))]), contains: "duplicate region id")
        expectFailure(recipeV2([region("a", shape: circle(5), channel: "ghost")]), contains: "channel \"ghost\" is not defined")
        expectFailure(recipeV2([region("a", shape: circle(5), color: "red")]), contains: "color \"red\" must look like")
        expectFailure(recipeV2([region("a", shape: circle(5), note: #""H3""#)]), contains: "not a defined note")
        expectFailure(recipeV2([]), contains: "regions: need 1–64")
        expectFailure(recipeV2((0..<65).map { region("r\($0)", shape: circle(1)) }), contains: "regions: need 1–64, found 65")
    }

    func testOfflineRadiusLimitIsAProcessingBoundNotAHardwareClaim() throws {
        expectFailure(recipeV2([region("a", shape: circle(5), at: #"{"yCm":100}"#)], play: rectArea(-800, 800, 0, 700)),
                      contains: "this offline kit processes at most 1000 cm", "not a statement about the scanner")
        expectFailure(recipeV2([region("a", shape: circle(5), at: #"{"yCm":100}"#)], play: #"{"type":"sector","fromCm":0,"toCm":1001,"fromDegrees":-90,"toDegrees":90}"#),
                      contains: "at most 1000 cm")
        expectFailure(recipeV2([region("a", shape: #"{"type":"sector","fromCm":900,"toCm":1001,"fromDegrees":-5,"toDegrees":5}"#)]), contains: "offline processing limit of 1000 cm")
        // Exactly at the limit is fine: a sector play area to 1000 cm and a region near its edge.
        let edge = try compile(recipeV2([region("a", shape: #"{"type":"sector","fromCm":990,"toCm":1000,"fromDegrees":-5,"toDegrees":5}"#)],
                                         play: #"{"type":"sector","fromCm":0,"toCm":1000,"fromDegrees":-90,"toDegrees":90}"#))
        XCTAssertEqual(cells(edge, "a").count, 10 * 20)
    }

    // MARK: Play area, error and clip

    func testOutsideCellsAreRefusedByDefaultAndClippedOnRequestWithCounts() throws {
        let sticking = region("e", shape: rect(20, 20), at: #"{"xCm":45,"yCm":10}"#)   // x 35…55, y 0…20; play area x < 50
        let area = rectArea(-50, 50, 0, 100)
        expectFailure(recipeV2([sticking], play: area), contains: "region \"e\"", "cells lie outside the play area", "outsidePolicy", "clip")
        let clipped = try compile(recipeV2([sticking], play: area, top: #""outsidePolicy":"clip","#))
        let kept = cells(clipped, "e")
        XCTAssertFalse(kept.contains(cell(50, 360)), "(50, 0) is the excluded upper play-area edge")
        XCTAssertTrue(kept.contains(cell(49, 360)))
        XCTAssertTrue(kept.allSatisfy { point($0).x < 50 - 1e-9 && point($0).x >= -50 })
        let line = clipped.plan.regions[0]
        XCTAssertLessThan(line.cells, line.generatedCells)
        XCTAssertEqual(line.cells, kept.count)
        XCTAssertTrue(clipped.plan.notices.contains { $0.contains("clipped to the play area: \(line.generatedCells) grid cells → \(line.cells) kept, \(line.generatedCells - line.cells) removed") }, "\(clipped.plan.notices)")
        XCTAssertTrue(clipped.plan.render().contains("\(line.cells) of \(line.generatedCells)"))
        // A region entirely inside is neither refused nor reported.
        let fine = try compile(recipeV2([region("e", shape: rect(20, 20), at: #"{"xCm":0,"yCm":50}"#)], play: area))
        XCTAssertFalse(fine.plan.notices.contains { $0.contains("clipped") })
    }

    func testShapesWithoutAnyCellAreAlwaysAnErrorEvenWhenClipping() {
        let clip = #""outsidePolicy":"clip","#
        // completely outside the play area
        expectFailure(recipeV2([region("far", shape: circle(10), at: #"{"xCm":150,"yCm":60}"#)], play: rectArea(-50, 50, 0, 100), top: clip),
                      contains: "region \"far\"", "lies completely outside the play area")
        expectFailure(recipeV2([region("far", shape: circle(10), at: #"{"xCm":0,"yCm":150}"#)], play: rectArea(-50, 50, 0, 100), top: clip),
                      contains: "completely outside the play area")
        // all its cells exist but none is inside
        expectFailure(recipeV2([region("near", shape: rect(30, 30), at: #"{"xCm":0,"yCm":115}"#)], play: rectArea(-50, 50, 0, 100), top: clip),
                      contains: "completely outside the play area")
        // entirely behind the scanner
        expectFailure(recipeV2([region("back", shape: circle(10), at: #"{"xCm":0,"yCm":-40}"#)], top: clip), contains: "entirely behind the scanner")
        expectFailure(recipeV2([region("back", shape: rect(30, 10), at: #"{"xCm":0,"yCm":-40}"#)]), contains: "entirely behind the scanner")
        // smaller than the grid: no 1 cm ring point falls inside
        expectFailure(recipeV2([region("tiny", shape: circle(0.1), at: #"{"xCm":0,"yCm":100.4}"#)], top: clip), contains: "produces no cells", "smaller than the 1 cm / 0.5° grid")
        expectFailure(recipeV2([region("tiny", shape: rect(0.2, 0.2), at: #"{"xCm":3,"yCm":50.5}"#)]), contains: "produces no cells")
    }

    func testPartAndWholeBehindTheScannerAreReportedOrClipped() throws {
        let straddling = region("half", shape: circle(20), at: #"{"xCm":0,"yCm":5}"#)
        expectFailure(recipeV2([straddling]), contains: "region \"half\"", "behind the scanner (y < 0)")
        let clipped = try compile(recipeV2([straddling], top: #""outsidePolicy":"clip","#))
        XCTAssertTrue(cells(clipped, "half").allSatisfy { point($0).y >= -1e-9 })
        XCTAssertTrue(clipped.plan.notices.contains { $0.contains("behind the scanner has no cells") })
    }

    func testLimitsOnWorkAndCellsRejectHugeInputsFast() throws {
        // 64 long slivers, each looking at ~360 000 grid points, would be tens of millions: refused by the explicit budgets.
        let discs = (0..<64).map { region("d\($0)", shape: rect(1500, 1), at: #"{"xCm":0,"yCm":500,"rotationDegrees":45}"#, channel: $0 % 2 == 0 ? "ch" : "b") }
        let started = Date()
        expectFailure(recipeV2(discs, play: #"{"type":"sector","fromCm":0,"toCm":1000,"fromDegrees":-90,"toDegrees":90}"#), contains: "work limit")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        // The cell budget: two big fans on different channels exceed one million assignments.
        let fans = (0..<4).map { region("f\($0)", shape: #"{"type":"sector","fromCm":1,"toCm":1000,"fromDegrees":-90,"toDegrees":90}"#, channel: $0 % 2 == 0 ? "ch" : "b") }
        expectFailure(recipeV2(fans, play: #"{"type":"sector","fromCm":0,"toCm":1000,"fromDegrees":-90,"toDegrees":90}"#), contains: "more than 1000000 cells")
        XCTAssertThrowsError(try PatchKitRecipe.decode(Data(repeating: 0x20, count: 300 * 1024)))
    }

    // MARK: Raster overlaps

    func testOverlapIsDecidedOnFinishedCellsNotBoundingBoxes() throws {
        // Two parallel diagonal bars 10 cm apart: their bounding boxes overlap heavily, no cell is shared.
        let barA = region("a", shape: rect(80, 6), at: #"{"xCm":0,"yCm":100,"rotationDegrees":45}"#)
        let barParallel = region("b", shape: rect(80, 6), at: #"{"xCm":-7.0711,"yCm":107.0711,"rotationDegrees":45}"#, note: #""D4""#, color: "#42A5F5")
        let parallel = try compile(recipeV2([barA, barParallel]))
        XCTAssertTrue(parallel.drawing.overlaps.isEmpty, "same channel is fine: no finished cell is shared")
        let boxA = PatchPlacedShape(shape: .rectangle(widthCm: 80, heightCm: 6), transform: PatchTransform(xCm: 0, yCm: 100, rotationDegrees: 45))
        let boxB = PatchPlacedShape(shape: .rectangle(widthCm: 80, heightCm: 6), transform: PatchTransform(xCm: -7.0711, yCm: 107.0711, rotationDegrees: 45))
        XCTAssertFalse(boxA.worldBounds.disjoint(from: boxB.worldBounds), "a bounding-box check alone would have refused this")
        // A bar turned the other way crosses the first one: shared cells on one channel name both IDs.
        let barCrossing = region("b", shape: rect(80, 6), at: #"{"xCm":0,"yCm":100,"rotationDegrees":-45}"#, note: #""D4""#, color: "#42A5F5")
        expectFailure(recipeV2([barA, barCrossing]), contains: "regions \"a\" and \"b\" share", "same channel")
        // ...but on another channel it is layering, counted and reported.
        let layered = try compile(recipeV2([barA, region("b", shape: rect(80, 6), at: #"{"xCm":0,"yCm":100,"rotationDegrees":-45}"#, note: #""D4""#, channel: "b", color: "#42A5F5")]))
        XCTAssertEqual(layered.drawing.overlaps.count, 1)
        XCTAssertFalse(layered.drawing.overlaps[0].sameChannel)
        XCTAssertEqual(layered.drawing.overlaps[0].cells, cells(layered, "a").intersection(cells(layered, "b")).count)
        XCTAssertGreaterThan(layered.drawing.overlaps[0].cells, 10)
        XCTAssertTrue(layered.plan.notices.contains { $0.contains("regions \"a\" and \"b\" layer on different channels") })
        XCTAssertTrue(try PatchPreview.svg(for: layered).contains("overlap: a × b"))
    }

    func testBoundariesDecideSharedCellsOnTheGrid() throws {
        // Rectangles use [lower, upper): neighbouring rectangles share no cell, also on one channel.
        let neighbours = try compile(recipeV2([region("n1", shape: rect(40, 20), at: #"{"xCm":0,"yCm":50}"#),
                                               region("n2", shape: rect(40, 20), at: #"{"xCm":0,"yCm":70}"#, note: #""D4""#)]))
        XCTAssertTrue(neighbours.drawing.overlaps.isEmpty)
        // Circles include their border: two circles touching at exactly one grid point do share that cell.
        expectFailure(recipeV2([region("c1", shape: circle(10), at: #"{"xCm":0,"yCm":50}"#), region("c2", shape: circle(10), at: #"{"xCm":0,"yCm":70}"#, note: #""D4""#)]),
                      contains: "regions \"c1\" and \"c2\" share 1 grid cells")
    }

    // MARK: Determinism, identifiers, sounds

    func testBuildsAreDeterministicAndReadByTheProductionReader() throws {
        let json = try String(contentsOf: examples.appendingPathComponent("mixed-shapes.recipe.json"))
        let first = try compile(json), second = try compile(json)
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(try PatchPreview.svg(for: first), try PatchPreview.svg(for: second))
        _ = try PresetDocumentReader.read(first.data).get()
        let decoded = try PresetV6Codec.decode(first.data)
        XCTAssertEqual(decoded, first.preset)
        XCTAssertNoThrow(try InstrumentCompiler.compile(decoded.document))
        XCTAssertEqual(decoded.document.spatial.layers.map(\.name), ["Turned box", "L mirrored", "Clipped circle", "Ring arc"])
        XCTAssertEqual(decoded.document.spatial.layers[0].id, PatchIdentity.uuid("layer", "tilted"), "identifiers derive from the region handles")
        XCTAssertEqual(decoded.document.spatial.layers.map { layer in Set(first.drawing.regions.first { $0.label == layer.name }!.cells) }, decoded.document.spatial.layers.map(\.cells))
        let strips = decoded.document.channels
        XCTAssertEqual(strips.count, 2); XCTAssertEqual(strips[1].inserts.count, 1)
        for layer in decoded.document.spatial.layers {
            XCTAssertEqual(layer.routings.count, 1)
            if case .chord(_, _, let transition) = layer.routings[0].program { XCTAssertEqual(transition, .legato) } else { XCTFail("gate chord expected") }
        }
        XCTAssertEqual(decoded.document.spatial.layers[3].routings[0].program, .chord(notes: [48], velocity: 60, transition: .legato))
    }

    func testMissingSoundsStillFailWithTheAliasInVersionTwo() {
        expectFailure(recipeV2([region("a", shape: circle(5), at: #"{"yCm":60}"#)]).replacingOccurrences(of: "\"surge.init\"", with: "\"ghost.organ\""),
                      contains: "ghost.organ")
    }

    // MARK: Plan text

    func testPlanNamesCoordinatesRotationAndRealCellCounts() throws {
        let build = try compile(try String(contentsOf: examples.appendingPathComponent("table-1m.recipe.json")))
        let text = build.plan.render()
        for needle in ["scanner fixed at (0, 0)", "+x right, +y forward", "-90° left, 0° front, +90° right", "counter-clockwise", "mirrorX flips",
                       "rectangle x -50…50 cm, y 20…100 cm", "not a measured room or a proven scanner range", "rectangle 40×30 cm", "circle r 15 cm", "polygon 3 points",
                       "\(build.plan.regions[0].cells)"] {
            XCTAssertTrue(text.contains(needle), "“\(needle)” missing in:\n\(text)")
        }
        XCTAssertEqual(build.plan.regions.map(\.cells), build.drawing.regions.map(\.cells.count))
        XCTAssertEqual(build.plan.regions.map(\.cells), [2963, 1591, 702], "measured: rectangle 40×30 at x -45…-5, y 25…55; circle r 15; triangle")
        XCTAssertEqual(cells(build, "low"), oracle(corners: [(-45, 25), (-5, 25), (-5, 55), (-45, 55)]), "the 2963 cells are exactly the grid points inside the rectangle")
    }

    // MARK: SVG preview

    private func preview(_ json: String) throws -> String { try PatchPreview.svg(for: try compile(json)) }

    func testPreviewIsWellFormedSelfContainedAndEscaped() throws {
        let hostile = recipeV2([region("a", shape: circle(10), at: #"{"yCm":60}"#)], top: "").replacingOccurrences(of: "\"T2\"", with: #""A<b>&\"'x""#)
        let svg = try preview(hostile)
        final class Delegate: NSObject, XMLParserDelegate { var elements: [String] = []; var attributes: [[String: String]] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
                elements.append(name); attributes.append(attributeDict) } }
        let delegate = Delegate()
        let parser = XMLParser(data: Data(svg.utf8)); parser.delegate = delegate
        XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError))")
        XCTAssertEqual(delegate.elements.first, "svg")
        XCTAssertTrue(svg.contains("A&lt;b&gt;&amp;&quot;&apos;x"), "name must be XML-escaped")
        XCTAssertFalse(svg.contains("A<b>"))
        for forbidden in ["<script", "<image", "<foreignObject", "<use", "href=", "xlink", "onload", "@import", "url(", "javascript:", "<style"] {
            XCTAssertFalse(svg.contains(forbidden), forbidden)
        }
        XCTAssertEqual(svg.components(separatedBy: "http").count - 1, 1, "the only URL is the SVG namespace declaration")
        XCTAssertEqual(delegate.attributes.first?["xmlns"], "http://www.w3.org/2000/svg")
        XCTAssertFalse(svg.contains("e+") || svg.contains("nan") || svg.contains("inf"), "locale-free plain numbers")
    }

    func testPreviewCoordinatesMatchCentimetreMeasurements() throws {
        let svg = try preview(try String(contentsOf: examples.appendingPathComponent("table-1m.recipe.json")))
        func numbers(in text: Substring) -> [Double] { text.split(whereSeparator: { " ,MLZ".contains($0) }).compactMap { Double($0) } }
        // Dashed play-area outline: M(xMin,yMin) L(xMax,yMin) L(xMax,yMax) L(xMin,yMax)
        let outline = svg.components(separatedBy: "\n").first { $0.contains("stroke-dasharray") }!
        let d = outline.components(separatedBy: "d=\"")[1].components(separatedBy: "\"")[0]
        let values = numbers(in: Substring(d))
        XCTAssertEqual(values.count, 8)
        let scale = (values[2] - values[0]) / 100                        // 100 cm wide
        XCTAssertEqual((values[1] - values[5]) / scale, 80, accuracy: 0.05) // 80 cm deep (y 20…100)
        // The scanner circle sits at x = 0 cm and y = 0 cm in the same frame.
        let scanner = svg.components(separatedBy: "\n").first { $0.contains("<circle") }!
        let cx = Double(scanner.components(separatedBy: "cx=\"")[1].components(separatedBy: "\"")[0])!, cy = Double(scanner.components(separatedBy: "cy=\"")[1].components(separatedBy: "\"")[0])!
        XCTAssertEqual((cx - values[0]) / scale, 50, accuracy: 0.05, "x = 0 is 50 cm right of the play area's left edge")
        XCTAssertEqual((cy - values[1]) / scale, 20, accuracy: 0.05, "the play area starts 20 cm in front of the scanner")
        // The scale bar's drawn length equals its labelled centimetres.
        let label = svg.components(separatedBy: "\n").first { $0.contains(" cm (1 cm / 0.5° grid cells") }!
        let labelled = Double(label.components(separatedBy: ">")[1].components(separatedBy: " cm")[0])!
        let bar = svg.components(separatedBy: "\n").first { $0.contains("stroke-width=\"2\"><line") }!
        let x1 = Double(bar.components(separatedBy: "x1=\"")[1].components(separatedBy: "\"")[0])!, x2 = Double(bar.components(separatedBy: "x2=\"")[1].components(separatedBy: "\"")[0])!
        XCTAssertEqual((x2 - x1) / scale, labelled, accuracy: 0.05)
        // Legend names region, notes and channel; every region has its own group.
        for needle in ["low (C4 box) · notes C4=60 · channel lead · 2963 cells", "mid (E4 circle) · notes E4=64", "high (G4 triangle) · notes G4=67", "Scanner (0, 0)", "+x", "+y"] {
            XCTAssertTrue(svg.contains(needle), needle)
        }
        XCTAssertEqual(svg.components(separatedBy: "<g id=\"region-").count - 1, 3)
    }

    func testPreviewDrawsEveryCellAndStaysSmallForBandsAndShapes() throws {
        let build = try compile(try String(contentsOf: examples.appendingPathComponent("mixed-shapes.recipe.json")))
        for region in build.drawing.regions {
            let boxes = PatchPreview.Box.merge(region.cells)
            var expanded = Set<PolarDeviceLattice>()
            for box in boxes { for ring in box.r0...box.r1 { for tick in box.t0...box.t1 { expanded.insert(cell(ring, tick)) } } }
            XCTAssertEqual(expanded, Set(region.cells), "\(region.id): boxes cover exactly the region's cells, no cell hidden or invented")
            XCTAssertEqual(boxes.map { ($0.r1 - $0.r0 + 1) * ($0.t1 - $0.t0 + 1) }.reduce(0, +), region.cells.count, "no cell drawn twice")
        }
        XCTAssertEqual(PatchPreview.Box.merge(build.drawing.regions[3].cells).count, 1, "the 4800-cell ring arc is one shape")
        let svg = try PatchPreview.svg(for: build)
        XCTAssertLessThan(svg.utf8.count, 60_000)
        // A band recipe of version 1: four bands of 14 440 cells each → four boxes, small file.
        let band = try String(contentsOf: examples.appendingPathComponent("chord-ladder.recipe.json"))
        let catalog = try SoundCatalog.load(from: try makeCatalog())
        let v1 = try PatchCompiler.compile(try PatchKitRecipe.decode(Data(band.utf8)), catalog: catalog)
        let v1svg = try PatchPreview.svg(for: v1)
        XCTAssertLessThan(v1svg.utf8.count, 12_000)
        XCTAssertTrue(v1svg.contains("Recipe version 1"))
        XCTAssertEqual(v1svg.components(separatedBy: "<g id=\"region-").count - 1, 4)
    }

    func testPreviewRefusesInsteadOfHidingCellsWhenTooFine() throws {
        let base = try compile(try String(contentsOf: examples.appendingPathComponent("table-1m.recipe.json")))
        // A checkerboard of 200 000 single cells cannot be drawn within the shape limit.
        var cells: [PolarDeviceLattice] = []
        for ring in 1..<1000 { for tick in stride(from: ring % 2, to: 361, by: 2) { cells.append(cell(ring, tick)) } }
        XCTAssertGreaterThan(PatchPreview.Box.merge(cells).count, PatchPreview.maximumBoxes)
        let dense = PatchBuild(preset: base.preset, data: base.data, plan: base.plan, inputStateFiles: base.inputStateFiles,
            drawing: PatchDrawing(name: "dense", version: 2, playArea: base.drawing.playArea,
                regions: [.init(id: "x", label: "x", channel: "ch", color: "#4CAF50", notes: [60], cells: cells)], overlaps: []))
        XCTAssertThrowsError(try PatchPreview.svg(for: dense)) { error in
            XCTAssertTrue("\(error)".contains("too fine to draw without leaving cells out"), "\(error)")
        }
    }

    func testPreviewCarriesNoSoundBytesAndNoStateContent() throws {
        let svg = try preview(try String(contentsOf: examples.appendingPathComponent("table-1m.recipe.json")))
        let state = try read(evidence.appendingPathComponent("surge-default-state.plist"))
        XCTAssertFalse(svg.contains(state.base64EncodedString().prefix(40)))
        XCTAssertFalse(svg.contains("SgXT") || svg.contains("dely") || svg.contains("jucePluginState") || svg.contains("surge.init"))
    }

    // MARK: Command line: check, build and preview use one plan

    private struct Run { var code: Int32; var out: String; var err: String }
    private func kit(_ arguments: [String]) -> Run {
        var out = "", err = ""
        let code = PatchKitCommand.run(arguments, out: { out += $0 }, err: { err += $0 })
        return Run(code: code, out: out, err: err)
    }

    func testCheckBuildAndPreviewShareTheSameInputsAndPlan() throws {
        let catalog = try makeCatalog()
        let recipeURL = try file("r.recipe.json", try read(examples.appendingPathComponent("mixed-shapes.recipe.json")))
        let recipeBytes = try read(recipeURL), catalogBytes = try read(catalog)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let checked = kit(["check", "--recipe", recipeURL.path, "--catalog", catalog.path])
        XCTAssertEqual(checked.code, 0, checked.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before, "check writes nothing")
        let presetURL = directory.appendingPathComponent("m.sickpreset.json"), svgURL = directory.appendingPathComponent("m.svg")
        let built = kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", presetURL.path])
        let previewed = kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", svgURL.path])
        XCTAssertEqual(built.code, 0, built.err); XCTAssertEqual(previewed.code, 0, previewed.err)
        XCTAssertEqual(try read(presetURL), try compile(String(decoding: recipeBytes, as: UTF8.self)).data)
        XCTAssertEqual(String(decoding: try read(svgURL), as: UTF8.self), try preview(String(decoding: recipeBytes, as: UTF8.self)))
        let plan = { (text: String) in text.components(separatedBy: "Check passed").first!.components(separatedBy: "Wrote ").first! }
        XCTAssertEqual(plan(checked.out), plan(built.out)); XCTAssertEqual(plan(checked.out), plan(previewed.out))
        // the written preset reads back through the production codec with the planned cell counts
        let decoded = try PresetV6Codec.decode(try read(presetURL))
        XCTAssertEqual(decoded.document.spatial.layers.map(\.cells.count), [1155, 1891, 1165, 4800])
        XCTAssertEqual(try read(recipeURL), recipeBytes); XCTAssertEqual(try read(catalog), catalogBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }, [], "no temporary files remain")
    }

    func testPreviewOutputProtectionMatchesBuild() throws {
        let catalog = try makeCatalog()
        let recipeURL = try file("r.recipe.json", try read(examples.appendingPathComponent("table-1m.recipe.json")))
        let output = directory.appendingPathComponent("p.svg")
        let first = kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path])
        XCTAssertEqual(first.code, 0, first.err)
        let svg = try read(output)
        try Data("precious".utf8).write(to: output)
        let refused = kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path])
        XCTAssertEqual(refused.code, 1); XCTAssertTrue(refused.err.contains("--force"))
        XCTAssertEqual(try read(output), Data("precious".utf8))
        XCTAssertEqual(kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path, "--force"]).code, 0)
        XCTAssertEqual(try read(output), svg)
        // a failing recipe leaves an existing output alone, even with --force
        let broken = try file("broken.json", Data(recipeV2([region("a", shape: circle(5), at: #"{"yCm":600}"#)]).utf8))
        XCTAssertEqual(kit(["preview", "--recipe", broken.path, "--catalog", catalog.path, "--out", output.path, "--force"]).code, 1)
        XCTAssertEqual(try read(output), svg)
        // the suffix is checked and a preset name is no preview name
        XCTAssertEqual(kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", directory.appendingPathComponent("p.png").path]).code, 1)
        XCTAssertEqual(kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", directory.appendingPathComponent("nofolder/p.svg").path]).code, 1)
        XCTAssertEqual(kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path]).code, 2)
        XCTAssertEqual(kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path, "--force", "--force"]).code, 2)
    }

    func testPreviewNeverOverwritesRecipeCatalogOrAnyStateFileEvenUnusedOrLinked() throws {
        let catalog = try makeCatalog()
        let recipeURL = try file("only.svg", try read(examples.appendingPathComponent("table-1m.recipe.json")))   // recipe that happens to end in .svg
        let recipeBytes = try read(recipeURL)
        XCTAssertEqual(kit(["preview", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", recipeURL.path, "--force"]).code, 1)
        XCTAssertEqual(try read(recipeURL), recipeBytes)
        // an unused catalog state (alias not referenced by the recipe) ends in .svg through a link as well
        let folder = catalog.deletingLastPathComponent()
        let unused = folder.appendingPathComponent("states/unused.svg")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("states/surge.init.plist"), to: unused)
        var json = try String(contentsOf: catalog)
        json = json.replacingOccurrences(of: "\"sounds\" : [", with: "\"sounds\" : [\n    { \"alias\" : \"unused.one\", \"role\" : \"instrument\", \"state\" : \"states/unused.svg\" },")
        try Data(json.utf8).write(to: catalog)
        let unusedBytes = try read(unused)
        let link = directory.appendingPathComponent("link.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unused)
        let clean = try file("table.recipe.json", try read(examples.appendingPathComponent("table-1m.recipe.json")))
        for target in [unused, link] {
            let result = kit(["preview", "--recipe", clean.path, "--catalog", catalog.path, "--out", target.path, "--force"])
            XCTAssertEqual(result.code, 1, result.out); XCTAssertTrue(result.err.contains("overwrite an input"), result.err)
            XCTAssertEqual(try read(unused), unusedBytes)
        }
        // the same protection holds for build with an unused state named like a preset
        let presetNamed = folder.appendingPathComponent("states/unused.sickpreset.json")
        try FileManager.default.copyItem(at: unused, to: presetNamed)
        json = json.replacingOccurrences(of: "states/unused.svg", with: "states/unused.sickpreset.json")
        try Data(json.utf8).write(to: catalog)
        let namedBytes = try read(presetNamed)
        XCTAssertEqual(kit(["build", "--recipe", clean.path, "--catalog", catalog.path, "--out", presetNamed.path, "--force"]).code, 1)
        XCTAssertEqual(try read(presetNamed), namedBytes)
    }

    func testNewExamplesBuildWithKitAndOldExamplesAreUntouched() throws {
        let catalog = try makeCatalog()
        for name in ["table-1m", "mixed-shapes", "simple-three-bands", "chord-ladder"] {
            let output = directory.appendingPathComponent("\(name).sickpreset.json"), svg = directory.appendingPathComponent("\(name).svg")
            let recipe = examples.appendingPathComponent("\(name).recipe.json")
            XCTAssertEqual(kit(["build", "--recipe", recipe.path, "--catalog", catalog.path, "--out", output.path]).code, 0, name)
            XCTAssertEqual(kit(["preview", "--recipe", recipe.path, "--catalog", catalog.path, "--out", svg.path]).code, 0, name)
            _ = try PresetDocumentReader.read(try read(output)).get()
        }
    }
}
