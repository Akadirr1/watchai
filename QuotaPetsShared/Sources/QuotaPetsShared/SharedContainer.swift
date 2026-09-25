import Foundation

/// The container shared between the watch app and its widget extension.
///
/// They are separate processes, so the snapshot has to live somewhere both can reach.
/// App Groups are available on a free Personal Team — Apple's watchOS capability
/// reference checks "App groups" in the free column and states outright that the watch
/// target's capabilities "don't depend on your program membership".
///
/// The container lookup is Apple-only (`containerURL(forSecurityApplicationGroupIdentifier:)`
/// does not exist in Foundation on Linux), so it is guarded. Keeping the guard here rather
/// than duplicating the identifier in two targets means there is still exactly one place
/// the group name is written, and the package keeps building — and testing — on Linux.
public enum SharedContainer {
    public static let appGroup = "group.com.quotapets"
    public static let snapshotFilename = "snapshot.json"

    /// The directory the snapshot lives in, falling back to Application Support when the
    /// App Group is unavailable (a misconfigured entitlement, or a non-Apple platform).
    public static func directory() -> URL {
        #if canImport(Darwin)
        if let shared = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return shared
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static func snapshotURL() -> URL {
        directory().appendingPathComponent(snapshotFilename)
    }

    /// What the complications last read, as a `UsageSnapshot.complicationDigest`. The
    /// widget writes it on every timeline it builds; the app reads it back to learn
    /// whether a reload it asked for really ran, since WidgetKit drops the ones past its
    /// daily budget without a word.
    public static func recordRendered(_ digest: [Int?]) {
        try? JSONEncoder().encode(digest).write(to: renderedURL(), options: .atomic)
    }

    public static func lastRendered() -> [Int?]? {
        guard let data = try? Data(contentsOf: renderedURL()) else { return nil }
        return try? JSONDecoder().decode([Int?].self, from: data)
    }

    private static func renderedURL() -> URL {
        directory().appendingPathComponent("rendered.json")
    }
}
