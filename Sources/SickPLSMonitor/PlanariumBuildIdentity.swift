import Foundation

/// Die auf dem Bundle sichtbare Identität des gebauten Stands.
///
/// Die Werte kommen aus der Info.plist, damit About-Panel, Diagnose und
/// exportierter Messbericht dieselbe Quelle verwenden.
struct PlanariumBuildIdentity: Equatable {
    let marketingVersion: String
    let buildNumber: String
    let gitRevision: String

    init(
        marketingVersion: String = "0.1",
        buildNumber: String = "unknown",
        gitRevision: String = "unknown"
    ) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.gitRevision = gitRevision
    }

    init(bundle: Bundle) {
        self.init(
            marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            gitRevision: bundle.object(forInfoDictionaryKey: "PlanariumGitRevision") as? String ?? "unknown"
        )
    }

    static var current: PlanariumBuildIdentity {
        PlanariumBuildIdentity(bundle: .main)
    }

    var aboutVersionText: String {
        "Version \(marketingVersion) · Build \(buildNumber)"
    }

    var standText: String {
        "Revision \(gitRevision)"
    }

    var presentationLine: String {
        "\(aboutVersionText)\n\(standText)"
    }
}
