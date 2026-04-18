import AppKit
import Combine
import CryptoKit
import Foundation
import SQLite3

enum ClipboardRetentionPolicy: String, CaseIterable, Identifiable {
    case oneWeek
    case oneMonth
    case threeMonths
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneWeek:
            return "7 Days"
        case .oneMonth:
            return "30 Days"
        case .threeMonths:
            return "90 Days"
        case .forever:
            return "Keep Forever"
        }
    }

    var menuTitle: String {
        switch self {
        case .oneWeek:
            return "Delete after 7 days"
        case .oneMonth:
            return "Delete after 30 days"
        case .threeMonths:
            return "Delete after 90 days"
        case .forever:
            return "Never delete automatically"
        }
    }

    var days: Int? {
        switch self {
        case .oneWeek:
            return 7
        case .oneMonth:
            return 30
        case .threeMonths:
            return 90
        case .forever:
            return nil
        }
    }

    var shortLabel: String {
        switch self {
        case .oneWeek:
            return "7d"
        case .oneMonth:
            return "30d"
        case .threeMonths:
            return "90d"
        case .forever:
            return "Off"
        }
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardHistoryItem] = []
    @Published private(set) var pinnedContentHashes: Set<String> = []
    @Published private(set) var retentionPolicy: ClipboardRetentionPolicy = .oneMonth

    let rootURL: URL
    let imagesDirectoryURL: URL

    private let databaseURL: URL
    private var database: OpaquePointer?
    private let maxItems = 200
    private let defaults = UserDefaults.standard
    private let pinnedDefaultsKey = "stackboard.pinnedHashes"
    private let retentionDefaultsKey = "stackboard.retentionPolicy"
    private let imageCache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = applicationSupport.appendingPathComponent("Stackboard", isDirectory: true)
        imagesDirectoryURL = rootURL.appendingPathComponent("images", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("clips.db", isDirectory: false)
        pinnedContentHashes = Set(defaults.stringArray(forKey: pinnedDefaultsKey) ?? [])
        retentionPolicy = ClipboardRetentionPolicy(rawValue: defaults.string(forKey: retentionDefaultsKey) ?? "") ?? .oneMonth

        prepareStorage()
        reload()
        removeExpiredItems(reloadAfterDeletion: false)
        reload()
    }

    deinit {
        sqlite3_close(database)
    }

    func ingest(_ snapshot: ClipboardSnapshot, createdAt: Date = .now) {
        switch snapshot {
        case let .text(text):
            upsertText(text, createdAt: createdAt)
        case let .image(image):
            upsertImage(image, createdAt: createdAt)
        case let .file(fileURL):
            upsertFile(fileURL, createdAt: createdAt)
        }

        reload()
        removeExpiredItems(reloadAfterDeletion: false)
        pruneIfNeeded()
        reload()
    }

    func image(for item: ClipboardHistoryItem) -> NSImage? {
        guard let imageRelativePath = item.imageRelativePath else {
            return nil
        }

        let cacheKey = NSString(string: item.contentHash)
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let url = imagesDirectoryURL.appendingPathComponent(imageRelativePath)
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func thumbnail(for item: ClipboardHistoryItem, maxDimension: CGFloat) -> NSImage? {
        guard item.kind == .image else {
            return nil
        }

        let key = NSString(string: "\(item.contentHash)-\(Int(maxDimension.rounded()))")
        if let cachedThumbnail = thumbnailCache.object(forKey: key) {
            return cachedThumbnail
        }

        guard let image = image(for: item) else {
            return nil
        }

        let thumbnail = image.thumbnail(maxDimension: maxDimension)
        thumbnailCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    func item(for id: UUID) -> ClipboardHistoryItem? {
        items.first { $0.id == id }
    }

    func fileURL(for item: ClipboardHistoryItem) -> URL? {
        guard let filePath = item.filePath else {
            return nil
        }

        return URL(fileURLWithPath: filePath)
    }

    func isPinned(_ item: ClipboardHistoryItem) -> Bool {
        pinnedContentHashes.contains(item.contentHash)
    }

    func togglePin(_ item: ClipboardHistoryItem) {
        if pinnedContentHashes.contains(item.contentHash) {
            pinnedContentHashes.remove(item.contentHash)
        } else {
            pinnedContentHashes.insert(item.contentHash)
        }
        persistPinnedHashes()
    }

    func delete(_ item: ClipboardHistoryItem) {
        delete(items: [item], reloadAfterDeletion: true)
    }

    func clear() {
        let paths = items.compactMap(\.imageRelativePath)
        for path in paths {
            let url = imagesDirectoryURL.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: url)
        }

        pinnedContentHashes = []
        persistPinnedHashes()
        imageCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        execute("DELETE FROM clips")
        reload()
    }

    func setRetentionPolicy(_ policy: ClipboardRetentionPolicy) {
        guard retentionPolicy != policy else {
            return
        }

        retentionPolicy = policy
        defaults.set(policy.rawValue, forKey: retentionDefaultsKey)
        removeExpiredItems(reloadAfterDeletion: false)
        reload()
    }

    func expiredItemCount(referenceDate: Date = .now) -> Int {
        expiredItems(referenceDate: referenceDate).count
    }

    func removeExpiredItems(referenceDate: Date = .now, reloadAfterDeletion: Bool = true) {
        let expired = expiredItems(referenceDate: referenceDate)
        guard expired.isEmpty == false else {
            return
        }

        delete(items: expired, reloadAfterDeletion: reloadAfterDeletion)
    }

    private func prepareStorage() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)

        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            return
        }

        execute(
            """
            CREATE TABLE IF NOT EXISTS clips (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                kind TEXT NOT NULL,
                text_value TEXT,
                image_path TEXT,
                content_hash TEXT NOT NULL UNIQUE
            );
            """
        )
    }

    private func reload() {
        items = fetchItems(limit: maxItems)
    }

    private func fetchItems(limit: Int) -> [ClipboardHistoryItem] {
        guard let database else {
            return []
        }

        let query = """
        SELECT id, created_at, kind, text_value, image_path, content_hash
        FROM clips
        ORDER BY created_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var result: [ClipboardHistoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let rawID = sqlite3_column_text(statement, 0),
                let rawKind = sqlite3_column_text(statement, 2),
                let rawHash = sqlite3_column_text(statement, 5)
            else {
                continue
            }

            let id = UUID(uuidString: String(cString: rawID)) ?? UUID()
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let kind = ClipboardContentKind(rawValue: String(cString: rawKind)) ?? .text
            let storedValue = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let imagePath = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let contentHash = String(cString: rawHash)
            let textValue = kind == .text ? storedValue : nil
            let filePath = kind == .file ? storedValue : nil

            result.append(
                ClipboardHistoryItem(
                    id: id,
                    createdAt: createdAt,
                    kind: kind,
                    textValue: textValue,
                    imageRelativePath: imagePath,
                    filePath: filePath,
                    contentHash: contentHash
                )
            )
        }

        return result
    }

    private func upsertText(_ text: String, createdAt: Date) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return
        }

        let contentHash = Self.hash(for: Data(normalized.utf8), prefix: "text")
        if updateTimestampIfNeeded(for: contentHash, createdAt: createdAt) {
            return
        }

        guard let database else {
            return
        }

        let query = """
        INSERT INTO clips (id, created_at, kind, text_value, image_path, content_hash)
        VALUES (?, ?, 'text', ?, NULL, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        defer { sqlite3_finalize(statement) }
        let id = UUID().uuidString
        sqlite3_bind_text(statement, 1, id, -1, transientSQLiteDestructor)
        sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, normalized, -1, transientSQLiteDestructor)
        sqlite3_bind_text(statement, 4, contentHash, -1, transientSQLiteDestructor)
        sqlite3_step(statement)
    }

    private func upsertImage(_ image: NSImage, createdAt: Date) {
        guard let pngData = image.pngData else {
            return
        }

        let contentHash = Self.hash(for: pngData, prefix: "image")
        if updateTimestampIfNeeded(for: contentHash, createdAt: createdAt) {
            return
        }

        let filename = "\(UUID().uuidString).png"
        let url = imagesDirectoryURL.appendingPathComponent(filename)

        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            return
        }

        guard let database else {
            return
        }

        let query = """
        INSERT INTO clips (id, created_at, kind, text_value, image_path, content_hash)
        VALUES (?, ?, 'image', NULL, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        defer { sqlite3_finalize(statement) }
        let id = UUID().uuidString
        sqlite3_bind_text(statement, 1, id, -1, transientSQLiteDestructor)
        sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, filename, -1, transientSQLiteDestructor)
        sqlite3_bind_text(statement, 4, contentHash, -1, transientSQLiteDestructor)

        if sqlite3_step(statement) != SQLITE_DONE {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func upsertFile(_ fileURL: URL, createdAt: Date) {
        let standardizedPath = fileURL.standardizedFileURL.path
        guard standardizedPath.isEmpty == false else {
            return
        }

        let contentHash = Self.hash(for: Data(standardizedPath.utf8), prefix: "file")
        if updateTimestampIfNeeded(for: contentHash, createdAt: createdAt) {
            return
        }

        guard let database else {
            return
        }

        let query = """
        INSERT INTO clips (id, created_at, kind, text_value, image_path, content_hash)
        VALUES (?, ?, 'file', ?, NULL, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        defer { sqlite3_finalize(statement) }
        let id = UUID().uuidString
        sqlite3_bind_text(statement, 1, id, -1, transientSQLiteDestructor)
        sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, standardizedPath, -1, transientSQLiteDestructor)
        sqlite3_bind_text(statement, 4, contentHash, -1, transientSQLiteDestructor)
        sqlite3_step(statement)
    }

    private func updateTimestampIfNeeded(for contentHash: String, createdAt: Date) -> Bool {
        guard let database else {
            return false
        }

        let query = "UPDATE clips SET created_at = ? WHERE content_hash = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, contentHash, -1, transientSQLiteDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            return false
        }

        return sqlite3_changes(database) > 0
    }

    private func pruneIfNeeded() {
        guard items.count >= maxItems else {
            return
        }

        let overflowCount = items.count - (maxItems - 1)
        guard overflowCount > 0 else {
            return
        }

        let pruneCandidates = items
            .sorted(by: { $0.createdAt < $1.createdAt })
            .filter { isPinned($0) == false }

        let itemsToDelete = Array(pruneCandidates.prefix(overflowCount))
        guard itemsToDelete.isEmpty == false else {
            return
        }

        delete(items: itemsToDelete, reloadAfterDeletion: false)
    }

    private func expiredItems(referenceDate: Date) -> [ClipboardHistoryItem] {
        guard let days = retentionPolicy.days else {
            return []
        }

        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: referenceDate) else {
            return []
        }

        return items.filter { item in
            item.createdAt < cutoffDate && isPinned(item) == false
        }
    }

    private func execute(_ query: String) {
        guard let database else {
            return
        }

        sqlite3_exec(database, query, nil, nil, nil)
    }

    private func persistPinnedHashes() {
        defaults.set(Array(pinnedContentHashes).sorted(), forKey: pinnedDefaultsKey)
    }

    private func delete(items: [ClipboardHistoryItem], reloadAfterDeletion: Bool) {
        guard items.isEmpty == false else {
            return
        }

        guard let database else {
            return
        }

        let query = "DELETE FROM clips WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        defer { sqlite3_finalize(statement) }

        for item in items {
            if let imageRelativePath = item.imageRelativePath {
                let url = imagesDirectoryURL.appendingPathComponent(imageRelativePath)
                try? FileManager.default.removeItem(at: url)
            }

            imageCache.removeObject(forKey: NSString(string: item.contentHash))
            removeThumbnailCacheEntries(for: item)
            pinnedContentHashes.remove(item.contentHash)

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, item.id.uuidString, -1, transientSQLiteDestructor)
            sqlite3_step(statement)
        }

        persistPinnedHashes()

        if reloadAfterDeletion {
            reload()
        }
    }

    private func removeThumbnailCacheEntries(for item: ClipboardHistoryItem) {
        for size in [34, 96] {
            thumbnailCache.removeObject(forKey: NSString(string: "\(item.contentHash)-\(size)"))
        }
    }

    private static func hash(for data: Data, prefix: String) -> String {
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix):\(hash)"
    }
}

private let transientSQLiteDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
