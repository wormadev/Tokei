import Foundation

/// An open incident on the provider's Statuspage that touches its coding agent. Nil: all clear.
struct ServiceStatus: Equatable, Sendable {
    enum Severity: Sendable { case minor, major }

    var title: String
    var severity: Severity
    var link: URL

    static func page(_ id: ProviderID) -> URL {
        switch id {
        case .claude: URL(string: "https://status.claude.com")!
        case .codex: URL(string: "https://status.openai.com")!
        }
    }

    /// Statuspage component names to watch. The pages also list chat, images and so on.
    static func components(_ id: ProviderID) -> [String] {
        switch id {
        case .claude: ["Claude Code", "Claude API"]
        case .codex: ["Codex"]
        }
    }

    static func fetch(_ id: ProviderID) async throws -> ServiceStatus? {
        let url = page(id).appending(path: "api/v2/summary.json")
        let summary = try await HTTP.json(Summary.self, URLRequest(url.absoluteString), unauthorizedHint: "")
        return parse(summary, watching: components(id), page: page(id))
    }

    struct Summary: Decodable {
        struct Component: Decodable {
            var name: String
            var status: String
        }

        struct Incident: Decodable {
            var name: String
            var shortlink: String?
            var components: [Component]?
        }

        struct Status: Decodable {
            var indicator: String
            var description: String
        }

        var status: Status
        var components: [Component]
        var incidents: [Incident]?
    }

    /// Watched components that aren't operational, named by the incident that covers them.
    /// If the page renames its components, falls back to the page-wide indicator.
    static func parse(_ summary: Summary, watching names: [String], page: URL) -> ServiceStatus? {
        let watched = summary.components.filter { component in
            names.contains { component.name.localizedCaseInsensitiveContains($0) }
        }
        guard !watched.isEmpty else {
            guard summary.status.indicator != "none" else { return nil }
            let severity: Severity = ["major", "critical"].contains(summary.status.indicator) ? .major : .minor
            return ServiceStatus(title: summary.status.description, severity: severity, link: page)
        }
        let affected = watched.filter { $0.status != "operational" }
        guard let first = affected.first else { return nil }
        let severity: Severity = affected.contains { $0.status.hasSuffix("outage") } ? .major : .minor
        let affectedNames = Set(affected.map(\.name))
        let incident = summary.incidents?.first { $0.components?.contains { affectedNames.contains($0.name) } == true }
        let title = incident?.name ?? "\(first.name): \(first.status.replacingOccurrences(of: "_", with: " "))"
        return ServiceStatus(title: title, severity: severity, link: incident?.shortlink.flatMap(URL.init(string:)) ?? page)
    }
}
