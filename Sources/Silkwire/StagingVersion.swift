import Foundation

/// Date-based version labels (Jason's choice): the day a build was made plus its
/// order that day among the builds on this Mac, e.g. 2026.10.26.3. Builds made
/// before builds recorded their time show as "Earlier build" with their code.
enum StagingVersion {
    static func day(_ date: Date) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy.MM.dd"
        return format.string(from: date)
    }
    /// Labels keyed by each build's content fingerprint, so an installed copy, its
    /// candidate and its backup all share one label.
    static func labels(_ identities: [StagingInstaller.Identity]) -> [String: String] {
        var labels: [String: String] = [:], perDay: [String: Int] = [:]
        let dated = identities.compactMap { identity in identity.builtAt.map { (identity, $0) } }.sorted { $0.1 < $1.1 }
        for (identity, builtAt) in dated where labels[identity.manifestSHA256] == nil {
            let d = day(builtAt)
            perDay[d, default: 0] += 1
            labels[identity.manifestSHA256] = "\(d).\(perDay[d]!)"
        }
        return labels
    }
    static func label(_ identity: StagingInstaller.Identity, in labels: [String: String]) -> String {
        labels[identity.manifestSHA256] ?? "Earlier build \(identity.shortRevision)"
    }
    static func builtText(_ identity: StagingInstaller.Identity) -> String? {
        identity.builtAt.map { "built " + $0.formatted(date: .abbreviated, time: .shortened) }
    }
}
