import Foundation

public enum FuzzyMatch {
    public static func score(query: String, candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }
        var positions: [Int] = []
        var searchFrom = 0
        for character in needle {
            guard let index = haystack[searchFrom...].firstIndex(of: character) else { return nil }
            positions.append(index)
            searchFrom = index + 1
        }
        let candidateWords = Array(candidate)
        var value = 0
        for (offset, position) in positions.enumerated() {
            value += 10
            if offset > 0 && position == positions[offset - 1] + 1 { value += 12 }
            if position == 0 || candidateWords[position - 1].isWhitespace ||
                "-_./".contains(candidateWords[position - 1]) {
                value += 10
            }
        }
        value -= max(0, haystack.count - needle.count)
        return value
    }
}
