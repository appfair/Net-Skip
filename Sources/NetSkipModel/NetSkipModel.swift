// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import Foundation
import OSLog
import Observation
import SkipSQL
import SkipWeb

let logger: Logger = Logger(subsystem: "net.skip", category: "NetSkipModel")


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

            let url = SQLValue.text(item.url.absoluteString)
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

        let fallbackURL = URL(string: "https://example.org")!

        var items: [PageInfo] = []
        while try statement.next() {
            let id = statement.integer(at: 0)
            let url = statement.string(at: 1) ?? ""
            let title = statement.string(at: 2)
            let date = statement.double(at: 3)

            let item = PageInfo(id: id, url: URL(string: url) ?? fallbackURL, title: title, date: Date(timeIntervalSince1970: date))
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
