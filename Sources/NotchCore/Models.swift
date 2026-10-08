import Foundation

public struct CategoryID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let communication: CategoryID = "communication"
    public static let code: CategoryID = "code"
    public static let browser: CategoryID = "browser"
    public static let media: CategoryID = "media"
    public static let school: CategoryID = "school"
    public static let system: CategoryID = "system"
    public static let other: CategoryID = "other"
}

public struct Category: Identifiable, Codable, Hashable, Sendable {
    public var id: CategoryID
    public var name: String
    public var symbol: String
    public var isBuiltIn: Bool

    public init(id: CategoryID, name: String, symbol: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isBuiltIn = isBuiltIn
    }

    public static let defaults: [Category] = [
        Category(id: .communication, name: "Communication", symbol: "bubble.left.and.bubble.right", isBuiltIn: true),
        Category(id: .code, name: "Code", symbol: "chevron.left.forwardslash.chevron.right", isBuiltIn: true),
        Category(id: .browser, name: "Browser", symbol: "globe", isBuiltIn: true),
        Category(id: .media, name: "Media", symbol: "play.rectangle", isBuiltIn: true),
        Category(id: .school, name: "School", symbol: "book", isBuiltIn: true),
        Category(id: .system, name: "System", symbol: "gearshape", isBuiltIn: true),
        Category(id: .other, name: "Other", symbol: "square.grid.2x2", isBuiltIn: true)
    ]
}

public struct WindowFeatures: Codable, Hashable, Sendable, Identifiable {
    public var windowID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String

    public var id: UInt32 { windowID }

    public init(windowID: UInt32, pid: Int32, bundleID: String?, appName: String, title: String) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }
}

public struct CategoryDistribution: Codable, Hashable, Sendable {
    public var probabilities: [CategoryID: Double]

    public init(probabilities: [CategoryID: Double] = [:]) {
        self.probabilities = probabilities
    }

    public static let abstain = CategoryDistribution()

    public func top(in order: [CategoryID]) -> CategoryID? {
        let orderedIDs = order + probabilities.keys.filter { !order.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        var best: (id: CategoryID, probability: Double)?
        for id in orderedIDs {
            guard let probability = probabilities[id], probability.isFinite else { continue }
            if best == nil || probability > best!.probability {
                best = (id, probability)
            }
        }
        return best?.id
    }

    public func normalized() -> CategoryDistribution {
        let valid = probabilities.filter { $0.value.isFinite && $0.value > 0 }
        let total = valid.values.reduce(0, +)
        guard total.isFinite, total > 0 else { return .abstain }
        return CategoryDistribution(probabilities: valid.mapValues { $0 / total })
    }
}

public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case bundleID(String)
        case titleKeyword(String, scopedToBundleIDs: [String]?)
    }

    public var id: UUID
    public var categoryID: CategoryID
    public var kind: Kind

    public init(id: UUID = UUID(), categoryID: CategoryID, kind: Kind) {
        self.id = id
        self.categoryID = categoryID
        self.kind = kind
    }
}

public struct Correction: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var categoryID: CategoryID
    public var createdAt: Date

    public var id: String { Self.key(bundleID: bundleID, appName: appName) + "\u{0}" + title }

    public init(bundleID: String?, appName: String, title: String, categoryID: CategoryID, createdAt: Date = Date()) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.categoryID = categoryID
        self.createdAt = createdAt
    }

    public static func key(bundleID: String?, appName: String) -> String {
        bundleID ?? appName
    }
}

public struct WindowGroup: Codable, Hashable, Sendable, Identifiable {
    public var category: Category
    public var windows: [WindowFeatures]
    public var id: CategoryID { category.id }

    public init(category: Category, windows: [WindowFeatures]) {
        self.category = category
        self.windows = windows
    }
}
