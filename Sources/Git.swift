import Foundation

let fm = FileManager.default
func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
func canonical(_ path: String) -> String { url(path).resolvingSymlinksInPath().standardizedFileURL.path }
func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
struct Failure: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
struct Output {
    let code: Int32
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines) }
    var fields: [String] { data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } }
}
func run(_ executable: String, _ args: [String], timeout: Double = 90) -> Output {
    let task = Process(), pipe = Pipe()
    task.executableURL = url(executable)
    task.arguments = args
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_NO_LAZY_FETCH"] = "1"
    env["GH_PROMPT_DISABLED"] = "1"
    env["GH_NO_UPDATE_NOTIFIER"] = "1"
    task.environment = env
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    task.standardInput = FileHandle.nullDevice
    do { try task.run() } catch { return Output(code: -1, data: Data()) }
    let timer = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    timer.cancel()
    return Output(code: task.terminationStatus, data: data)
}
func git(_ path: String, _ args: [String]) -> Output {
    let literal = args.first == "check-ignore" ? [] : ["--literal-pathspecs"]
    return run("/usr/bin/git", literal + ["--no-pager", "-c", "core.fsmonitor=false",
                         "-c", "core.hooksPath=/dev/null", "-C", path] + args)
}
struct Tree: Codable, Equatable, Identifiable {
    let path, main, head: String
    let branch: String?
    let locked, missing: Bool
    var id: String { path }
    var repo: String { url(main).lastPathComponent }
}
func listing(_ path: String) throws -> [Tree] {
    let result = git(path, ["worktree","list","--porcelain","-z"])
    guard result.code == 0, let raw = String(data: result.data, encoding: .utf8) else {
        throw Failure("Não foi possível listar os worktrees em " + path)
    }
    var main: String?
    var items: [Tree] = []
    for record in raw.components(separatedBy: "\0\0") {
        let fields = record.components(separatedBy: "\0")
        guard let first = fields.first, first.hasPrefix("worktree ") else { continue }
        let work = canonical(String(first.dropFirst(9)))
        guard let primary = main else { main = work; continue }
        func value(_ prefix: String) -> String? {
            fields.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        items.append(Tree(path: work, main: primary, head: value("HEAD ") ?? "",
                          branch: value("branch refs/heads/"), locked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                          missing: !fm.fileExists(atPath: work + "/.git")))
    }
    return items
}
struct Roots: Codable {
    var paths = [NSHomeDirectory() + "/Development", NSHomeDirectory() + "/.codex/worktrees"]
    var rules: [String:String] = [:]
    static let tools = ["Codex","Claude","Copilot","Outra"]
    var copilotTemplate: String? {
        let dir = ProcessInfo.processInfo.environment["COPILOT_HOME"] ?? NSHomeDirectory() + "/.copilot"
        for name in ["settings.json","config.json"] {
            if let data = fm.contents(atPath: dir + "/" + name),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
               let template = obj["worktreePathTemplate"] as? String {
                return (template as NSString).expandingTildeInPath
            }
        }
        return nil
    }
    func tool(_ path: String) -> String {
        if let match = rules.keys.filter({ inside(path, $0) }).max(by: { $0.count < $1.count }) { return rules[match]! }
        let codex = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        if inside(path, codex + "/worktrees") { return "Codex" }
        if path.contains("/.claude/worktrees/") { return "Claude" }
        if path.contains("/.copilot/worktrees/") || path.contains("/.copilot/workspaces/") { return "Copilot" }
        if let template = copilotTemplate {
            let pattern = template.components(separatedBy: CharacterSet(charactersIn: "{}"))
                .enumerated().map { $0.offset % 2 == 1 ? ".+" : NSRegularExpression.escapedPattern(for: $0.element) }.joined()
            if path.range(of: "^" + pattern + "$", options: .regularExpression) != nil { return "Copilot" }
        }
        return "Desconhecida"
    }
}
func discover(_ roots: [String], found: (Tree) -> Void, issue: @escaping (String) -> Void) {
    var checked = Set<String>(), emitted = Set<String>()
    let skip = Set([".git","node_modules",".build","build","target",".dart_tool",".venv","Pods","DerivedData",".pnpm-store",".gradle",".pytest_cache",".ruff_cache",".next",".cache","__pycache__"])
    func inspect(_ directory: URL) {
        let path = directory.path
        guard !checked.contains(path) else { return }
        let bare = fm.fileExists(atPath: path + "/HEAD") && fm.fileExists(atPath: path + "/objects")
        guard bare || fm.fileExists(atPath: path + "/.git") else { return }
        checked.insert(path)
        do {
            for tree in try listing(path) {
                checked.formUnion([tree.main,tree.path])
                if emitted.insert(tree.path).inserted { found(tree) }
            }
        } catch { issue(error.localizedDescription) }
    }
    for path in Set(roots.map(canonical)).sorted() {
        inspect(url(path))
        if checked.contains(path) { continue }
        guard let walk = fm.enumerator(at: url(path), includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey],
            options: [], errorHandler: { p,_ in issue("Sem acesso a " + p.path); return true }) else { continue }
        for case let entry as URL in walk {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if skip.contains(entry.lastPathComponent) || checked.contains(entry.path) { walk.skipDescendants(); continue }
            inspect(entry)
            if fm.fileExists(atPath: entry.path + "/.git") { walk.skipDescendants() }
        }
    }
}
