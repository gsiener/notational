import Foundation

// Isolated design probe for issue #30. No production UI or credential path uses this file.
struct Site: Equatable {
    let key: String
    let title: String
    let url: URL
    let ownership: String
}

enum RefreshError: Error { case invalidResponse, http(Int) }

protocol SitePageAdapter {
    func page(cursor: String?) throws -> Data
}

struct Snapshot {
    let accountID: String
    private(set) var sites: [Site] = []
    private(set) var stale = false

    mutating func refresh(using adapter: SitePageAdapter) throws {
        var collected: [Site] = []
        var cursor: String? = nil
        var seen = Set<String>()
        do {
            repeat {
                let data = try adapter.page(cursor: cursor)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = root["publishes"] as? [[String: Any]] else { throw RefreshError.invalidResponse }
                for row in rows {
                    guard (row["status"] as? String) == "active",
                          let slug = row["slug"] as? String, !slug.isEmpty,
                          let ownership = row["ownership"] as? String,
                          let rawURL = (row["primaryUrl"] as? String) ?? (row["siteUrl"] as? String),
                          let url = URL(string: rawURL), url.scheme == "https", url.host != nil else { continue }
                    let workspace = row["workspace"] as? [String: Any]
                    let scope = (workspace?["subdomain"] as? String) ?? ownership
                    let title = ((row["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? slug
                    let site = Site(key: "\(accountID):\(scope):\(slug)", title: title, url: url, ownership: ownership)
                    if !collected.contains(where: { $0.key == site.key }) { collected.append(site) }
                }
                cursor = root["nextCursor"] as? String
                if let cursor = cursor, !seen.insert(cursor).inserted { throw RefreshError.invalidResponse }
            } while cursor != nil
            sites = collected
            stale = false
        } catch {
            stale = true
            throw error
        }
    }
}

#if PROTOTYPE_TEST
struct Fake: SitePageAdapter {
    let pages: [String: String]
    func page(cursor: String?) throws -> Data {
        guard let text = pages[cursor ?? "first"] else { throw RefreshError.http(401) }
        return Data(text.utf8)
    }
}

func check(_ value: Bool, _ message: String) { precondition(value, message) }
var snapshot = Snapshot(accountID: "user-1")
let first = #"{"publishes":[{"slug":"a","siteUrl":"https://a.here.now/","displayName":"Alpha","ownership":"owned","status":"active"}],"nextCursor":"two"}"#
let second = #"{"publishes":[{"slug":"b","siteUrl":"https://b.here.now/","primaryUrl":"https://example.org/","ownership":"workspace","workspace":{"subdomain":"team"},"status":"active"}],"nextCursor":null}"#
try snapshot.refresh(using: Fake(pages: ["first": first, "two": second]))
check(snapshot.sites.count == 2 && snapshot.sites[1].key == "user-1:team:b", "all pages and separate account/workspace identity")
check(snapshot.sites[1].url.absoluteString == "https://example.org/", "primary URL")
do { try snapshot.refresh(using: Fake(pages: ["first": first])); preconditionFailure("expected authentication failure") }
catch { check(snapshot.stale && snapshot.sites.count == 2, "failed partial refresh preserves snapshot") }
do { try snapshot.refresh(using: Fake(pages: [:])); preconditionFailure("expected offline failure") }
catch { check(snapshot.stale && snapshot.sites.count == 2, "offline refresh preserves snapshot") }
do { try snapshot.refresh(using: Fake(pages: ["first": #"{"publishes":{}}"#])); preconditionFailure("expected malformed response") }
catch { check(snapshot.stale && snapshot.sites.count == 2, "unavailable or malformed response preserves snapshot") }
try snapshot.refresh(using: Fake(pages: ["first": #"{"publishes":[],"nextCursor":null}"#]))
check(!snapshot.stale && snapshot.sites.isEmpty, "successful empty inventory clears snapshot")
print("here.now read prototype: 6 checks passed")
#endif
