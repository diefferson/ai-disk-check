import Foundation
import SQLite3

struct Attribution {
    var tool: String
    var reason: String
}

struct HistoryFile: Codable {
    var size: Int64
    var modified: Date
    var paths: Set<String>
}

// Read only successful tool executions. Messages mentioning a path, commands proposed
// in chat, and sessions opened in a checkout do not establish who created it.
enum CreationHistory {
    private static let token = try! NSRegularExpression(pattern: #"(?:^|\s+)('[^']*'|"[^"$`]*"|[\w./~:@%+=,-]+)(?=\s|$)"#)
    private static func words(_ command: String) -> [String]? {
        let ns = command as NSString
        var end = 0, result = [String]()
        for m in token.matches(in:command,range:NSRange(location:0,length:ns.length)) {
            guard m.range.location == end else { return nil }
            var word = ns.substring(with:m.range(at:1))
            if word.hasPrefix("'") || word.hasPrefix("\"") { word.removeFirst(); word.removeLast() }
            result.append(word); end = NSMaxRange(m.range)
        }
        return end == ns.length ? result : nil
    }
    static func destinations(_ command: String, cwd: String) -> Set<String> {
        // Only accept simple commands or an all-success (&&) chain. Do not interpret
        // shell expansions, scripts, pipelines, conditionals or quoted examples.
        guard !command.contains("\n"), !command.contains(";"), !command.contains("||") else { return [] }
        var base = cwd, paths = Set<String>()
        func path(_ arg: String, under parent: String) -> String? {
            let p = (arg as NSString).expandingTildeInPath
            guard p.hasPrefix("/") || parent.hasPrefix("/") else { return nil }
            return canonical(p.hasPrefix("/") ? p : parent + "/" + p)
        }
        for part in command.components(separatedBy:"&&") {
            guard let args = words(part.trimmingCharacters(in:.whitespaces)), !args.isEmpty else { return [] }
            if args[0] == "cd" {
                guard args.count == 2, let dir = path(args[1], under:base) else { return [] }
                base = dir; continue
            }
            guard ["git","/usr/bin/git"].contains(args[0]) else { continue }
            var dir = base, i = 1
            while i + 1 < args.count && ["-C","-c"].contains(args[i]) {
                if args[i] == "-C" { guard let next = path(args[i+1],under:dir) else { return [] }; dir = next }
                i += 2
            }
            guard Array(args.dropFirst(i).prefix(2)) == ["worktree","add"] else { continue }
            i += 2
            while i < args.count && args[i].hasPrefix("-") {
                switch args[i] {
                case "-b","-B","--reason": i += 2
                case "--detach","-d","-f","--force","--lock","--no-checkout","--track","--no-track","-q","--quiet","--": i += 1
                default: return []
                }
            }
            if i < args.count, let dest = path(args[i],under:dir) { paths.insert(dest) }
        }
        return paths
    }
    static func read(_ file: URL, tool: String) -> Set<String> {
        guard let fp = fopen(file.path,"r") else { return [] }
        var buffer: UnsafeMutablePointer<CChar>?, capacity = 0
        defer { free(buffer); fclose(fp) }
        var result = Set<String>(), pending = [String:Set<String>]()
        while true {
            let n = getline(&buffer,&capacity,fp)
            guard n > 0, let line = buffer else { break }
            guard n < 8_000_000, strstr(line,"worktree add") != nil || (!pending.isEmpty && strstr(line,"tool_result") != nil) else { continue }
            let data = Data(bytesNoCopy:line,count:n,deallocator:.none)
            guard let entry = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { continue }
            if tool == "Codex" {
                guard let payload = entry["payload"] as? [String:Any], payload["type"] as? String == "item_completed",
                      let item = payload["item"] as? [String:Any], item["type"] as? String == "CommandExecution",
                      item["exit_code"] as? Int == 0, let args = item["command"] as? [String],
                      args.count == 3, ["-lc","-c"].contains(args[1]), let cwd = item["cwd"] as? String else { continue }
                let dir = cwd.hasPrefix("file:") ? URL(string:cwd)?.path ?? "" : cwd
                result.formUnion(destinations(args[2],cwd:dir))
            } else if let msg = entry["message"] as? [String:Any], let blocks = msg["content"] as? [[String:Any]] {
                for block in blocks {
                    if block["type"] as? String == "tool_use", block["name"] as? String == "Bash",
                       let id = block["id"] as? String, let input = block["input"] as? [String:Any],
                       let command = input["command"] as? String {
                        let paths = destinations(command,cwd:entry["cwd"] as? String ?? "")
                        if !paths.isEmpty { pending[id] = paths }
                    } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                              let paths = pending.removeValue(forKey:id), block["is_error"] as? Bool != true {
                        result.formUnion(paths)
                    }
                }
            }
        }
        return result
    }
}
struct OriginIndex {
    var creators = [String:Set<String>]()
    var files = [String:HistoryFile]()
    init() {}
    init(previous: [String:HistoryFile]) {
        let env = ProcessInfo.processInfo.environment, home = NSHomeDirectory()
        let codex = env["CODEX_HOME"] ?? home + "/.codex"
        let claude = env["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
        for (dir,tool) in [(codex+"/sessions","Codex"),(codex+"/archived_sessions","Codex"),(claude+"/projects","Claude")] {
            let keys: Set<URLResourceKey> = [.fileSizeKey,.contentModificationDateKey,.isRegularFileKey,.isSymbolicLinkKey]
            guard let walker = fm.enumerator(at:url(dir),includingPropertiesForKeys:Array(keys)) else { continue }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let attrs = try? file.resourceValues(forKeys:keys), attrs.isRegularFile == true, attrs.isSymbolicLink != true,
                      let count = attrs.fileSize, let stamp = attrs.contentModificationDate else { continue }
                let record: HistoryFile
                if let old = previous[file.path], old.size == count, old.modified == stamp { record = old }
                else { record = HistoryFile(size:Int64(count),modified:stamp,paths:CreationHistory.read(file,tool:tool)) }
                files[file.path] = record
                for p in record.paths { creators[p,default:[]].insert(tool) }
            }
        }
        let copilot = env["COPILOT_HOME"] ?? home + "/.copilot"
        var db: OpaquePointer?, stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        if sqlite3_open_v2(copilot+"/data.db",&db,SQLITE_OPEN_READONLY,nil) == SQLITE_OK,
           sqlite3_prepare_v2(db,"SELECT path FROM worktrees",-1,&stmt,nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let val = sqlite3_column_text(stmt,0) {
                    let path = String(cString:val)
                    if path.hasPrefix("/") { creators[canonical(path),default:[]].insert("Copilot") }
                }
            }
        }
    }
    func attribution(_ tree: Tree, roots: Roots) -> Attribution {
        let p = tree.path
        let original = roots.tool(p)
        if original != "Desconhecida" { return Attribution(tool:original,reason:"Pasta configurada ou padrão da ferramenta") }
        let candidates = creators[p] ?? []
        if candidates.count == 1 { return Attribution(tool:candidates.first!,reason:"Criação registrada pela ferramenta para este caminho") }
        if candidates.count > 1 { return Attribution(tool:"Desconhecida",reason:"Mais de uma ferramenta registrou criação neste caminho") }
        let components = url(p).pathComponents
        for (name,tool) in [("copilot-worktrees","Copilot"),("codex-worktrees","Codex"),("claude-worktrees","Claude")] where components.dropLast().contains(name) {
            return Attribution(tool:tool,reason:"Inferida pela pasta " + name)
        }
        if p.range(of:#"^/(?:private/)?tmp/claude-[0-9]+/[^/]+/[^/]+/scratchpad/"#,options:.regularExpression) != nil {
            return Attribution(tool:"Claude",reason:"Scratchpad de sessão do Claude")
        }
        if inside(p,NSHomeDirectory()+"/Documents/Codex") { return Attribution(tool:"Codex",reason:"Inferida pela pasta Documents/Codex") }
        if let prefix = tree.branch?.split(separator:"/").first, tree.branch?.contains("/") == true,
           let tool = Roots.tools.first(where:{ $0 != "Outra" && $0.lowercased() == prefix.lowercased() }) {
            return Attribution(tool:tool,reason:"Inferida pelo prefixo da branch " + prefix + "/")
        }
        return Attribution(tool:"Desconhecida",reason:"Sem registro de criação ou convenção reconhecida")
    }
}
