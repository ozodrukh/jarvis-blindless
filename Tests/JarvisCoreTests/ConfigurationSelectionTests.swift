import XCTest
@testable import JarvisCore

final class ConfigurationSelectionTests: XCTestCase {
    func testRemembersOnlySelectedLocationAcrossInstances() throws {
        let suite = "JarvisConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ConfigurationSelection(defaults: defaults)
        XCTAssertNil(first.url)
        let url = URL(fileURLWithPath: "/tmp/voice settings.json")
        first.remember(url)
        let second = ConfigurationSelection(defaults: defaults)
        XCTAssertEqual(second.url, url)
        XCTAssertEqual(defaults.dictionaryRepresentation()["jarvis.configurationPath"] as? String, url.path)
    }
}
