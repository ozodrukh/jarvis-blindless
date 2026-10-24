import Foundation

public final class ConfigurationSelection {
    private let defaults: UserDefaults
    private let key = "jarvis.configurationPath"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var url: URL? {
        defaults.string(forKey: key).map { URL(fileURLWithPath: $0) }
    }

    // Call only after the worker has validated the candidate file.
    public func remember(_ url: URL) { defaults.set(url.standardizedFileURL.path, forKey: key) }
}
