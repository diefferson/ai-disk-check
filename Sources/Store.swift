import Foundation
import SQLite3

struct Row: Codable, Identifiable {
    var tree: Tree
    var tool: String
    var originReason: String?
    var technologies: [String]?
    var disk: Measure?
    var state: GitState?
    var pull: Pull?
    var id: String { tree.path }
}
final class Store {
    private var db: OpaquePointer?
    init(directory: URL) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories:true)
        guard sqlite3_open(directory.appendingPathComponent("inventory.sqlite").path, &db) == SQLITE_OK,
              sqlite3_exec(db,"CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, value BLOB NOT NULL)",nil,nil,nil) == SQLITE_OK else {
            throw Failure("Não foi possível abrir o cache SQLite.")
        }
    }
    deinit { sqlite3_close(db) }
    func read<T: Decodable>(_ key: String, as: T.Type) -> T? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,"SELECT value FROM cache WHERE key=?",-1,&stmt,nil) == SQLITE_OK else { return nil }
        return key.withCString { ptr in
            sqlite3_bind_text(stmt,1,ptr,-1,nil)
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt,0) else { return nil }
            return try? JSONDecoder().decode(T.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(stmt,0))))
        }
    }
    func save<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO cache VALUES (?,?)",-1,&stmt,nil) == SQLITE_OK else { throw Failure("Falha ao preparar cache.") }
        let code = key.withCString { ptr in data.withUnsafeBytes { bytes in
            sqlite3_bind_text(stmt,1,ptr,-1,nil)
            sqlite3_bind_blob(stmt,2,bytes.baseAddress,Int32(bytes.count),nil)
            return sqlite3_step(stmt)
        } }
        guard code == SQLITE_DONE else { throw Failure("Falha ao salvar cache.") }
    }
}
