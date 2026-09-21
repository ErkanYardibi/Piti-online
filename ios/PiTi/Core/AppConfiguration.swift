import Foundation

enum AppConfiguration {
    static let environment = Bundle.main.object(forInfoDictionaryKey: "PiTiEnvironment") as? String ?? "staging"
    static let apnsEnvironment = Bundle.main.object(forInfoDictionaryKey: "PiTiAPNsEnvironment") as? String ?? "sandbox"
    static let productionHosts: Set<String> = ["mypiti.online", "www.mypiti.online", "piti-online.erkan-yardibi.workers.dev"]
    static var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PiTiBaseURL") as? String,
              let url = URL(string: value), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !host.isEmpty, !host.contains("$"), !host.hasSuffix(".invalid") else { return nil }
        if environment != "production", productionHosts.contains(host) { return nil }
        return url
    }
    static func isTrusted(_ url: URL?) -> Bool {
        guard let url, let base = baseURL else { return false }
        return url.scheme == "https" && url.host == base.host && url.port == base.port && url.user == nil && url.password == nil
    }
}
