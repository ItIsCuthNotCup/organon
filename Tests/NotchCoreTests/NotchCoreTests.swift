import Foundation
import NotchCore
import Testing

@Suite("NotchCore")
struct NotchCoreTests {
    @Test func acceptanceSetClassifiesEveryWindow() async {
        let inputs: [(String, String, CategoryID)] = [
            ("com.apple.Safari", "Safari", .browser),
            ("com.google.Chrome", "Google", .browser),
            ("com.microsoft.VSCode", "main.swift — organon", .code),
            ("com.apple.dt.Xcode", "Notch.xcodeproj", .code),
            ("com.apple.Terminal", "zsh", .code),
            ("com.apple.mail", "Inbox", .communication),
            ("com.apple.MobileSMS", "Messages", .communication),
            ("com.tinyspeck.slackmacgap", "general", .communication),
            ("com.hnc.Discord", "#general", .communication),
            ("com.google.Chrome", "Home / X", .communication),
            ("com.apple.Safari", "(2) Elon Musk on X: …", .communication),
            ("com.spotify.client", "Spotify Premium", .media),
            ("com.apple.finder", "Downloads", .system),
            ("com.apple.Preview", "paper.pdf", .school),
            ("com.apple.Notes", "Notes", .school),
            ("com.apple.iCal", "Calendar", .communication)
        ]
        let windows = inputs.enumerated().map { index, input in
            WindowFeatures(windowID: UInt32(index), pid: Int32(index), bundleID: input.0,
                           appName: input.0, title: input.1)
        }
        let pipeline = ClassificationPipeline(stages: [RulesClassifier(rules: DefaultRules.rules)])
        let groups = await pipeline.groups(windows)
        let assignments = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.windows.map { ($0.windowID, group.category.id) }
        })
        let correct = inputs.enumerated().filter { assignments[UInt32($0.offset)] == $0.element.2 }.count
        let rate = Double(correct) / Double(inputs.count) * 100
        print("Acceptance classification rate: \(correct)/\(inputs.count) (\(rate)%)")
        #expect(correct == inputs.count)
    }

    @Test func everySeededBundleMapsToItsCategory() async {
        let bundleRules = DefaultRules.rules.compactMap { rule -> (String, CategoryID)? in
            guard case let .bundleID(identifier) = rule.kind else { return nil }
            return (identifier, rule.categoryID)
        }
        #expect(bundleRules.count >= 40)
        let windows = bundleRules.enumerated().map { index, value in
            WindowFeatures(windowID: UInt32(index), pid: Int32(index), bundleID: value.0,
                           appName: value.0, title: "Window")
        }
        let distributions = await RulesClassifier(rules: DefaultRules.rules).classify(windows, categories: Category.defaults)
        #expect(distributions.enumerated().allSatisfy { index, distribution in
            distribution.top(in: Category.defaults.map(\.id)) == bundleRules[index].1
        })
    }

    @Test func keywordRulesAreScopedToBrowsers() async {
        let window = WindowFeatures(windowID: 1, pid: 1, bundleID: "com.microsoft.VSCode",
                                    appName: "Visual Studio Code", title: "discord.ts")
        let result = await RulesClassifier(rules: DefaultRules.rules).classify([window], categories: Category.defaults)
        #expect(result[0].top(in: Category.defaults.map(\.id)) == .code)
    }

    @Test func grouperAlwaysAssignsEveryWindowOnce() {
        for trial in 0..<500 {
            let extras = (0..<(trial % 4)).map {
                Category(id: CategoryID(rawValue: "custom-\($0)"), name: "Custom \($0)", symbol: "star")
            }
            let categories = Array(Category.defaults.dropLast()) + extras + [Category.defaults.last!]
            let count = Int.random(in: 1...50)
            let windows = (0..<count).map {
                WindowFeatures(windowID: UInt32(trial * 100 + $0), pid: Int32($0),
                              bundleID: nil, appName: "App", title: "Window \($0)")
            }
            let ids = categories.map(\.id) + [CategoryID(rawValue: "unknown")]
            let distributions = windows.map { _ -> CategoryDistribution in
                if Bool.random() { return .abstain }
                return CategoryDistribution(probabilities: [ids.randomElement()!: Double.random(in: 0...1)])
            }
            let groups = Grouper.group(windows: windows, distributions: distributions, categories: categories)
            let grouped = groups.flatMap(\.windows)
            #expect(grouped.count == windows.count)
            #expect(Set(grouped.map(\.windowID)).count == windows.count)
            #expect(groups.allSatisfy { !$0.windows.isEmpty })
            if let otherIndex = groups.firstIndex(where: { $0.category.id == .other }) {
                #expect(otherIndex == groups.count - 1)
            }
        }
    }

    @Test func correctionsPersistReplaceAndSessionOverrideWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)
        var config = try store.load()
        let window = WindowFeatures(windowID: 21, pid: 100, bundleID: "example.app", appName: "Example", title: "Project")
        try store.addCorrection(Correction(bundleID: window.bundleID, appName: window.appName,
                                           title: window.title, categoryID: .school), to: &config)
        try store.addCorrection(Correction(bundleID: window.bundleID, appName: window.appName,
                                           title: window.title, categoryID: .media), to: &config)
        #expect(config.corrections.count == 1)
        let reloaded = try ConfigStore(directory: directory).load()
        let pipeline = ClassificationPipeline(stages: [CorrectionClassifier(corrections: reloaded.corrections)])
        let corrected = await pipeline.classify([window])
        #expect(corrected[0].top(in: Category.defaults.map(\.id)) == .media)
        let overridden = await pipeline.classify([window], sessionOverrides: [window.windowID: .code])
        #expect(overridden[0].top(in: Category.defaults.map(\.id)) == .code)
    }

    @Test func fuzzyMatchOrdersContiguousAndRejectsNonSubsequence() {
        let contiguous = FuzzyMatch.score(query: "vsc", candidate: "Visual Studio Code")
        #expect(contiguous != nil)
        let tightRun = FuzzyMatch.score(query: "abc", candidate: "abc sample")
        let scattered = FuzzyMatch.score(query: "abc", candidate: "a---b---c")
        #expect(tightRun != nil)
        #expect(scattered != nil)
        #expect(tightRun! > scattered!)
        #expect(FuzzyMatch.score(query: "xyz", candidate: "Visual Studio Code") == nil)
    }

    @Test func coActivitySuggestsCliquesAndHonorsDismissalsAndAssignments() {
        let store = CoActivityStore()
        for bucket in 0..<40 {
            let date = Date(timeIntervalSince1970: Double(bucket * 30))
            store.record(key: "A", at: date)
            store.record(key: "B", at: date)
            store.record(key: "C", at: date)
        }
        store.flush()
        let suggestion = GroupSuggester.suggest(store: store, currentAssignment: [:], dismissed: [])
        #expect(suggestion?.keys == ["A", "B", "C"])
        #expect(GroupSuggester.suggest(store: store, currentAssignment: [:],
                                       dismissed: [["C", "A", "B"]]) == nil)
        #expect(GroupSuggester.suggest(store: store,
                                       currentAssignment: ["A": .code, "B": .code, "C": .code],
                                       dismissed: []) == nil)
    }

    @Test func decisionModelNormalizesAndAbstainsOnError() async {
        let window = WindowFeatures(windowID: 1, pid: 1, bundleID: nil, appName: "App", title: "Title")
        let classifier = DecisionModelClassifier(backend: FakeBackend(throwsError: false))
        let result = await classifier.classify([window], categories: Category.defaults)
        #expect(result[0].probabilities == [.code: 0.75, .school: 0.25])
        let failing = DecisionModelClassifier(backend: FakeBackend(throwsError: true))
        let abstained = await failing.classify([window], categories: Category.defaults)
        #expect(abstained == [.abstain])
    }
}

private struct FakeBackend: DecisionModelBackend {
    let throwsError: Bool

    func scores(for windows: [WindowFeatures], labels: [CategoryID]) async throws -> [[CategoryID: Double]] {
        if throwsError { throw TestFailure.failed }
        return Array(repeating: [.code: 3, .school: 1, "unknown": 8], count: windows.count)
    }
}

private enum TestFailure: Error {
    case failed
}
