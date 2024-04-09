// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import Foundation
import OSLog
import Observation
import SkipSQL
import SkipWeb

let logger: Logger = Logger(subsystem: "net.skip", category: "NetSkipModel")

/// Notification posted by the model when the content rules are loaded
extension Notification.Name {
    public static var webContentRulesLoaded: Notification.Name {
        return Notification.Name("webContentRulesLoaded")
    }
}

/// A store for persisting `WebBrowser` state such as history, favorites, and preferences.
public protocol WebBrowserStore {
    func saveItems(type: PageInfo.PageType, items: [PageInfo]) throws -> [PageInfo.ID]
    func loadItems(type: PageInfo.PageType, ids: Set<PageInfo.ID>) throws -> [PageInfo]
    func removeItems(type: PageInfo.PageType, ids: Set<PageInfo.ID>) throws
}

/// Information about a web page, for storing in the history or favorites list
public struct PageInfo : Identifiable {
    public typealias ID = Int64

    /// Whether the page is a favorite bookmark or history item
    public enum PageType {
        case history
        case favorite
        case active
    }

    /// The ID of this history item if it is persistent; 0 indicates that it is new
    public var id: ID
    public var url: URL?
    public var title: String?
    public var date: Date

    public init(id: ID = Int64(0), url: URL?, title: String? = nil, date: Date = Date.now) {
        self.id = id
        self.url = url
        self.title = title
        self.date = date
    }
}

/// The configuration for a search engine
public struct SearchEngine : Identifiable {
    public typealias ID = String

    public let id: ID
    public let homeURL: String
    public let name: () -> String
    public let queryURL: (String, String) -> String?
    public let suggestionURL: (String, String) -> String?

    public init(id: String, homeURL: String, name: @escaping () -> String, queryURL: @escaping (String, String) -> String?, suggestionURL: @escaping (String, String) -> String?) {
        self.id = id
        self.homeURL = homeURL
        self.name = name
        self.queryURL = queryURL
        self.suggestionURL = suggestionURL
    }
}


extension PageInfo.PageType {
    public var tableName: String {
        switch self {
        case .favorite: return "favorite"
        case .history: return "history"
        case .active: return "active"
        }
    }
}

/// A WebBrowserStore that is backed by a SQLContext
public class NetSkipWebBrowserStore : WebBrowserStore {
    let ctx: SQLContext

    static let schemaVersionTable = "schema_version"

    public init(url: URL?) throws {
        self.ctx = try SQLContext(path: url?.path ?? ":memory:", flags: [.readWrite, .create], logLevel: .info) // , configuration: .plus)
        try self.initializeSchema()
    }

    public func saveItems(type: PageInfo.PageType, items: [PageInfo]) throws -> [PageInfo.ID] {
        let table = type.tableName

        var ids: [PageInfo.ID] = []

        let newID = PageInfo.ID(0)

        for item in items {
            logger.log("saveItem: \(table) \(item.id)")

            // URL is not nullable, but we want to be able to store a null URL, so default to blank
            let url = SQLValue.text(item.url?.absoluteString ?? "")
            let title = item.title.flatMap { SQLValue.text($0) } ?? SQLValue.null
            let date = SQLValue.float(item.date.timeIntervalSince1970)

            let statement: SQLStatement
            if item.id != newID { // id=0 means new record
                statement = try ctx.prepare(sql: "UPDATE \(table) SET url = ?, title = ?, date = ? WHERE id = ?")
            } else {
                statement = try ctx.prepare(sql: "INSERT INTO \(table) (url, title, date) VALUES (?, ?, ?)")
            }

            try statement.bind(url, at: 1)
            try statement.bind(title, at: 2)
            try statement.bind(date, at: 3)
            if item.id != newID {
                try statement.bind(SQLValue.integer(item.id), at: 4)
            }

            defer { do { try statement.close() } catch {} }
            try statement.update()
            ids.append(item.id != newID ? item.id : ctx.lastInsertRowID)
        }
        return ids
    }

    public func loadItems(type: PageInfo.PageType, ids: Set<PageInfo.ID>) throws -> [PageInfo] {
        let table = type.tableName
        logger.log("loadItem: \(table) \(ids)")

        let statement: SQLStatement
        if ids.isEmpty {
            statement = try ctx.prepare(sql: "SELECT id, url, title, date FROM \(table) ORDER BY date DESC")
        } else {
            statement = try ctx.prepare(sql: "SELECT id, url, title, date FROM \(table) WHERE id IN (\(ids.map(\.description).joined(separator: ","))) ORDER BY date DESC")
        }
        defer { do { try statement.close() } catch {} }

        var items: [PageInfo] = []
        while try statement.next() {
            let id = statement.integer(at: 0)
            let url = statement.string(at: 1) ?? ""
            let title = statement.string(at: 2)
            let date = statement.double(at: 3)

            let item = PageInfo(id: id, url: URL(string: url), title: title, date: Date(timeIntervalSince1970: date))
            items.append(item)
        }
        return items
    }

    public func removeItems(type: PageInfo.PageType, ids: Set<PageInfo.ID>) throws {
        let table = type.tableName

        let statement = try ids.isEmpty
            ? ctx.prepare(sql: "DELETE FROM \(table)")
            : ctx.prepare(sql: "DELETE FROM \(table) WHERE id IN (\(ids.map(\.description).joined(separator: ",")))")

        defer { do { try statement.close() } catch {} }
        try statement.update()
    }

    private func initializeSchema() throws {
        /// The SQL for creating a PageInfo table
        func createTableSQL(_ type: PageInfo.PageType) -> String {
            "CREATE TABLE \(type.tableName) (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, title TEXT, date FLOAT NOT NULL)"
        }

        // perform the additive migration from earlier schema versions
        var currentVersion = try currentSchemaVersion()
        currentVersion = try migrateSchema(v: Int64(1), current: currentVersion, ddl: createTableSQL(.history))
        currentVersion = try migrateSchema(v: Int64(2), current: currentVersion, ddl: createTableSQL(.favorite))
        currentVersion = try migrateSchema(v: Int64(3), current: currentVersion, ddl: createTableSQL(.active))
    }

    private func currentSchemaVersion() throws -> Int64 {
        try ctx.exec(sql: "CREATE TABLE IF NOT EXISTS \(Self.schemaVersionTable) (id INTEGER PRIMARY KEY, version INTEGER)")
        try ctx.exec(sql: "INSERT OR IGNORE INTO \(Self.schemaVersionTable) (id, version) VALUES (0, 0)")
        return try ctx.query(sql: "SELECT version FROM \(Self.schemaVersionTable)").first?.first?.integerValue ?? Int64(0)
    }

    private func migrateSchema(v version: Int64, current: Int64, ddl: String) throws -> Int64 {
        guard current < version else {
            return current
        }
        let startTime = Date.now
        try ctx.transaction {
            try ctx.exec(sql: ddl)
            try ctx.exec(sql: "UPDATE \(Self.schemaVersionTable) SET version = ?", parameters: [.integer(version)])
        }
        logger.log("updated database schema to \(version) in \(Date.now.timeIntervalSince1970 - startTime.timeIntervalSince1970)")
        return version
    }

}
