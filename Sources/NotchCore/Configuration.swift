import Foundation

public struct HotKeySpec: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    // Carbon controlKey.
    public init(keyCode: UInt32 = 50, carbonModifiers: UInt32 = 0x00001000) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

public struct Settings: Codable, Hashable, Sendable {
    public var hotKey: HotKeySpec
    public var openOnNotchHover: Bool
    public var suggestNewGroups: Bool
    public var dismissedSuggestions: [[String]]

    public init(hotKey: HotKeySpec = HotKeySpec(), openOnNotchHover: Bool = true,
                suggestNewGroups: Bool = true, dismissedSuggestions: [[String]] = []) {
        self.hotKey = hotKey
        self.openOnNotchHover = openOnNotchHover
        self.suggestNewGroups = suggestNewGroups
        self.dismissedSuggestions = dismissedSuggestions
    }
}

public struct NotchConfiguration: Codable, Hashable, Sendable {
    public var version: Int
    public var categories: [Category]
    public var rules: [Rule]
    public var corrections: [Correction]
    public var settings: Settings
    public var hasCompletedOnboarding: Bool

    public init(version: Int = 1, categories: [Category] = Category.defaults, rules: [Rule] = DefaultRules.rules,
                corrections: [Correction] = [], settings: Settings = Settings(), hasCompletedOnboarding: Bool = false) {
        self.version = version
        self.categories = categories
        self.rules = rules
        self.corrections = corrections
        self.settings = settings
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

public final class ConfigStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notch", isDirectory: true)
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }

    public func load() throws -> NotchConfiguration {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                let seeded = NotchConfiguration()
                try saveUnlocked(seeded)
                return seeded
            }
            var configuration = try decoder.decode(NotchConfiguration.self, from: Data(contentsOf: configURL))
            if configuration.settings.hotKey.keyCode == 50,
               configuration.settings.hotKey.carbonModifiers == 0x00000100 {
                configuration.settings.hotKey.carbonModifiers = 0x00001000
            }
            return configuration
        }
    }

    public func save(_ configuration: NotchConfiguration) throws {
        try lock.withLock { try saveUnlocked(configuration) }
    }

    public func restoreDefaultRules(in configuration: inout NotchConfiguration) throws {
        configuration.rules = DefaultRules.rules
        try save(configuration)
    }

    public func addCorrection(_ correction: Correction, to configuration: inout NotchConfiguration) throws {
        let key = Correction.key(bundleID: correction.bundleID, appName: correction.appName)
        configuration.corrections.removeAll {
            Correction.key(bundleID: $0.bundleID, appName: $0.appName) == key && $0.title == correction.title
        }
        configuration.corrections.append(correction)
        try save(configuration)
    }

    public func addCategory(_ category: Category, to configuration: inout NotchConfiguration) throws {
        guard !configuration.categories.contains(where: { $0.id == category.id }) else { return }
        configuration.categories.insert(category, at: max(0, configuration.categories.count - 1))
        try save(configuration)
    }

    public func renameCategory(_ id: CategoryID, name: String, symbol: String? = nil,
                               in configuration: inout NotchConfiguration) throws {
        guard let index = configuration.categories.firstIndex(where: { $0.id == id }) else { return }
        configuration.categories[index].name = name
        if let symbol { configuration.categories[index].symbol = symbol }
        try save(configuration)
    }

    public func removeCategory(_ id: CategoryID, from configuration: inout NotchConfiguration) throws {
        guard let category = configuration.categories.first(where: { $0.id == id }), !category.isBuiltIn else { return }
        configuration.categories.removeAll { $0.id == id }
        configuration.rules.removeAll { $0.categoryID == id }
        configuration.corrections.removeAll { $0.categoryID == id }
        try save(configuration)
    }

    private func saveUnlocked(_ configuration: NotchConfiguration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(configuration).write(to: configURL, options: .atomic)
    }
}
