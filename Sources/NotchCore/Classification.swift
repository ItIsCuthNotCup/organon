import Foundation

public protocol Classifier: Sendable {
    var name: String { get }
    func classify(_ windows: [WindowFeatures], categories: [Category]) async -> [CategoryDistribution]
}

public struct CorrectionClassifier: Classifier {
    public let name = "Corrections"
    private let corrections: [String: CategoryID]

    public init(corrections: [Correction]) {
        self.corrections = Dictionary(corrections.map {
            (Correction.key(bundleID: $0.bundleID, appName: $0.appName) + "\u{0}" + $0.title, $0.categoryID)
        }, uniquingKeysWith: { _, latest in latest })
    }

    public func classify(_ windows: [WindowFeatures], categories: [Category]) async -> [CategoryDistribution] {
        windows.map { window in
            let key = Correction.key(bundleID: window.bundleID, appName: window.appName) + "\u{0}" + window.title
            guard let category = corrections[key] else { return .abstain }
            return CategoryDistribution(probabilities: [category: 1])
        }
    }
}

public struct RulesClassifier: Classifier {
    public let name = "Rules"
    private let rules: [Rule]

    public init(rules: [Rule]) {
        self.rules = rules
    }

    public func classify(_ windows: [WindowFeatures], categories: [Category]) async -> [CategoryDistribution] {
        windows.map { window in
            let keywordRule = rules.first { rule in
                guard case let .titleKeyword(keyword, scope) = rule.kind,
                      window.title.range(of: keyword, options: [.caseInsensitive]) != nil else { return false }
                return scope == nil || scope!.contains(window.bundleID ?? "")
            }
            let bundleRule = rules.first { rule in
                guard case let .bundleID(bundleID) = rule.kind else { return false }
                return bundleID == window.bundleID
            }
            guard let match = keywordRule ?? bundleRule else { return .abstain }
            return CategoryDistribution(probabilities: [match.categoryID: 1])
        }
    }
}

public struct LearnedClassifier: Classifier {
    public let name = "Learned activity"
    private let store: CoActivityStore

    public init(store: CoActivityStore) {
        self.store = store
    }

    /// v2 will use co-activity patterns as a local prior; this stage intentionally abstains.
    public func classify(_ windows: [WindowFeatures], categories: [Category]) async -> [CategoryDistribution] {
        _ = store
        return Array(repeating: .abstain, count: windows.count)
    }
}

public protocol DecisionModelBackend: Sendable {
    func scores(for windows: [WindowFeatures], labels: [CategoryID]) async throws -> [[CategoryID: Double]]
}

public struct DecisionModelClassifier<Backend: DecisionModelBackend>: Classifier {
    public let name = "Decision model"
    private let backend: Backend

    public init(backend: Backend) {
        self.backend = backend
    }

    public func classify(_ windows: [WindowFeatures], categories: [Category]) async -> [CategoryDistribution] {
        do {
            let labels = categories.map(\.id)
            let scores = try await backend.scores(for: windows, labels: labels)
            return windows.indices.map { index in
                guard scores.indices.contains(index) else { return .abstain }
                let known = scores[index].filter { labels.contains($0.key) }
                return CategoryDistribution(probabilities: known).normalized()
            }
        } catch {
            return Array(repeating: .abstain, count: windows.count)
        }
    }
}

public struct ClassificationPipeline: Sendable {
    public let stages: [any Classifier]
    public let categories: [Category]

    public init(stages: [any Classifier], categories: [Category] = Category.defaults) {
        self.stages = stages
        self.categories = categories
    }

    public static func defaults(corrections: [Correction], rules: [Rule], store: CoActivityStore,
                                categories: [Category] = Category.defaults) -> ClassificationPipeline {
        ClassificationPipeline(
            stages: [CorrectionClassifier(corrections: corrections), LearnedClassifier(store: store), RulesClassifier(rules: rules)],
            categories: categories
        )
    }

    public func classify(_ windows: [WindowFeatures], sessionOverrides: [UInt32: CategoryID] = [:]) async -> [CategoryDistribution] {
        var results = Array(repeating: CategoryDistribution.abstain, count: windows.count)
        for stage in stages {
            let output = await stage.classify(windows, categories: categories)
            for index in windows.indices where results[index].probabilities.isEmpty && output.indices.contains(index) {
                if !output[index].probabilities.isEmpty {
                    results[index] = output[index]
                }
            }
        }
        for (index, window) in windows.enumerated() {
            if let override = sessionOverrides[window.windowID] {
                results[index] = CategoryDistribution(probabilities: [override: 1])
            }
        }
        return results
    }

    public func groups(_ windows: [WindowFeatures], sessionOverrides: [UInt32: CategoryID] = [:]) async -> [WindowGroup] {
        let distributions = await classify(windows, sessionOverrides: sessionOverrides)
        return Grouper.group(windows: windows, distributions: distributions, categories: categories)
    }
}

public enum Grouper {
    public static func group(windows: [WindowFeatures], distributions: [CategoryDistribution],
                             categories: [Category]) -> [WindowGroup] {
        let ordered = categories.filter { $0.id != .other } + categories.filter { $0.id == .other }
        var assignments: [CategoryID: [WindowFeatures]] = [:]
        for (index, window) in windows.enumerated() {
            let proposed = distributions.indices.contains(index) ? distributions[index].top(in: ordered.map(\.id)) : nil
            let categoryID = proposed.flatMap { id in ordered.contains(where: { $0.id == id }) ? id : nil } ?? .other
            assignments[categoryID, default: []].append(window)
        }
        var groups = ordered.compactMap { category -> WindowGroup? in
            guard let windows = assignments[category.id], !windows.isEmpty else { return nil }
            return WindowGroup(category: category, windows: windows)
        }
        if !assignments[.other, default: []].isEmpty, !ordered.contains(where: { $0.id == .other }) {
            groups.append(WindowGroup(category: Category.defaults.last!, windows: assignments[.other]!))
        }
        return groups
    }
}

public enum DefaultRules {
    public static let rules: [Rule] = {
        let definitions: [(CategoryID, [String])] = [
            (.communication, ["com.apple.mail", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.microsoft.Outlook", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.FaceTime", "com.apple.iCal", "com.readdle.smartemail-Mac", "com.facebook.archon"]),
            (.code, ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.github.GitHubClient", "com.docker.docker", "com.postmanlabs.mac"]),
            (.browser, ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]),
            (.media, ["com.spotify.client", "com.apple.Music", "com.apple.TV", "com.apple.Photos", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.apple.podcasts", "com.figma.Desktop"]),
            (.school, ["com.apple.Notes", "com.apple.Preview", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "md.obsidian", "notion.id", "com.apple.reminders"]),
            (.system, ["com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.Console", "com.apple.AppStore", "com.apple.calculator", "com.1password.1password", "com.apple.Passwords"])
        ]
        let bundles = definitions.flatMap { category, identifiers in identifiers.map { Rule(categoryID: category, kind: .bundleID($0)) } }
        let browserIDs = definitions.first(where: { $0.0 == .browser })!.1
        let keywords: [(CategoryID, [String])] = [
            (.communication, ["/ X", " on X", "X / Twitter", "Twitter", "Gmail", "Slack", "Discord", "WhatsApp", "Messenger", "LinkedIn", "Outlook", "Google Calendar"]),
            (.code, ["GitHub", "GitLab", "Stack Overflow", "localhost", "Vercel", "Cloudflare"]),
            (.media, ["YouTube", "Netflix", "Twitch", "Spotify", "Prime Video", "Disney+"]),
            (.school, ["Canvas", "Gradescope", "Piazza", "Ed Discussion", "Coursera", "Khan Academy", "Google Docs", "Overleaf", "Wikipedia"])
        ]
        let keywordRules = keywords.flatMap { category, values in
            values.map { Rule(categoryID: category, kind: .titleKeyword($0, scopedToBundleIDs: browserIDs)) }
        }
        return bundles + keywordRules
    }()
}
