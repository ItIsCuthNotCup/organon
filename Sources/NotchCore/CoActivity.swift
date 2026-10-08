import Foundation

public struct CoActivitySnapshot: Codable, Sendable {
    public var bucketCount: [String: Int]
    public var pairCount: [String: Int]

    public init(bucketCount: [String: Int] = [:], pairCount: [String: Int] = [:]) {
        self.bucketCount = bucketCount
        self.pairCount = pairCount
    }
}

public final class CoActivityStore: @unchecked Sendable {
    private struct ActiveBucket {
        var id: Int64
        var keys: Set<String>
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private var active: ActiveBucket?
    private var snapshot: CoActivitySnapshot
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        fileURL = directory?.appendingPathComponent("learning.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode(CoActivitySnapshot.self, from: data) {
            snapshot = stored
        } else {
            snapshot = CoActivitySnapshot()
        }
    }

    public func record(key: String, at date: Date = Date()) {
        lock.withLock {
            let bucket = Int64(floor(date.timeIntervalSince1970 / 30))
            if let current = active, current.id != bucket {
                commit(current)
                active = ActiveBucket(id: bucket, keys: [key])
            } else if active == nil {
                active = ActiveBucket(id: bucket, keys: [key])
            } else {
                active?.keys.insert(key)
            }
        }
    }

    public func flush() {
        lock.withLock {
            if let active {
                commit(active)
                self.active = nil
            }
        }
    }

    public func counts() -> CoActivitySnapshot {
        lock.withLock { snapshot }
    }

    private func commit(_ bucket: ActiveBucket) {
        guard bucket.keys.count >= 2 else { return }
        for key in bucket.keys {
            snapshot.bucketCount[key, default: 0] += 1
        }
        let keys = bucket.keys.sorted()
        for leftIndex in keys.indices {
            for rightIndex in keys.indices where rightIndex > leftIndex {
                let pair = "\(keys[leftIndex])|\(keys[rightIndex])"
                snapshot.pairCount[pair, default: 0] += 1
            }
        }
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}

public struct GroupSuggestion: Hashable, Sendable {
    public var keys: [String]
    public var categoryID: CategoryID?

    public init(keys: [String], categoryID: CategoryID? = nil) {
        self.keys = keys.sorted()
        self.categoryID = categoryID
    }
}

public enum GroupSuggester {
    public static func suggest(store: CoActivityStore, currentAssignment: [String: CategoryID],
                               dismissed: [[String]]) -> GroupSuggestion? {
        let counts = store.counts()
        let edges = counts.pairCount.compactMap { pair, count -> (String, String, Int)? in
            guard count >= 15 else { return nil }
            let parts = pair.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let denominator = counts.bucketCount[parts[0], default: 0] +
                counts.bucketCount[parts[1], default: 0] - count
            guard denominator > 0, Double(count) / Double(denominator) >= 0.6 else { return nil }
            return (parts[0], parts[1], count)
        }.sorted { $0.2 > $1.2 }
        guard let strongest = edges.first else { return nil }
        var clique = [strongest.0, strongest.1]
        while clique.count < 4 {
            let next = counts.bucketCount.keys.filter { candidate in
                !clique.contains(candidate) && clique.allSatisfy { member in
                    edges.contains { ($0.0 == member && $0.1 == candidate) || ($0.0 == candidate && $0.1 == member) }
                }
            }.max { left, right in
                let leftScore = clique.compactMap { member in edges.first { ($0.0 == member && $0.1 == left) || ($0.0 == left && $0.1 == member) }?.2 }.reduce(0, +)
                let rightScore = clique.compactMap { member in edges.first { ($0.0 == member && $0.1 == right) || ($0.0 == right && $0.1 == member) }?.2 }.reduce(0, +)
                return leftScore < rightScore
            }
            guard let next else { break }
            clique.append(next)
        }
        let sorted = clique.sorted()
        let assigned = Set(sorted.compactMap { currentAssignment[$0] })
        guard assigned.count > 1 || assigned.count == 0 else { return nil }
        guard !dismissed.contains(where: { $0.sorted() == sorted }) else { return nil }
        return GroupSuggestion(keys: sorted)
    }
}
