import Foundation
import Darwin
import CryptoKit

struct Folder: Codable, Hashable, Identifiable {
    let path: String
    let bytes: Int64
    var id: String { path }
}
struct Measure: Codable {
    var bytes: Int64 = 0
    var builds = [Folder]()
    var folders = [Folder]()
    var partial = false
    var nested = false
    var stamp = ""
    var measured = Date()
    var buildBytes: Int64 { builds.reduce(0) { $0 + $1.bytes } }
}
struct Inode: Hashable { let device: dev_t; let number: ino_t }
func metadata(_ path: String) -> stat? {
    var s = stat()
    return lstat(path, &s) == 0 ? s : nil
}
private func manifestMatches(_ path: String) -> Bool {
    let dir = url(path), parent = dir.deletingLastPathComponent()
    let name: String
    switch dir.lastPathComponent {
    case ".build": name = "Package.swift"
    case "target": name = "Cargo.toml"
    case "build": name = "pubspec.yaml"
    default: return false
    }
    let manifest = parent.appendingPathComponent(name).path
    guard let s = metadata(manifest), s.st_mode & S_IFMT == S_IFREG else { return false }
    if name != "pubspec.yaml" { return true }
    guard s.st_size < 2_000_000, let content = try? String(contentsOfFile: manifest, encoding: .utf8) else { return false }
    return content.range(of: #"(?m)^\s*sdk:\s*flutter\s*(?:#.*)?$"#, options: .regularExpression) != nil
}
func measure(_ tree: Tree, excluded: Set<String>, links: inout Set<Inode>, fingerprint: Bool = false) -> Measure {
    var result = Measure(), top = [Folder](), hash = SHA256()
    let root = tree.path
    guard let rootStat = metadata(root), rootStat.st_mode & S_IFMT == S_IFDIR else { result.partial = true; return result }
    func visit(_ p: String, candidate: String?, safe: inout Bool) -> Int64 {
        guard let s = metadata(p) else { result.partial = true; safe = false; return 0 }
        if fingerprint {
            let info = [p, String(s.st_dev),String(s.st_ino),String(s.st_mode),String(s.st_size),
                        String(s.st_ctimespec.tv_sec),String(s.st_ctimespec.tv_nsec)].joined(separator: "\0") + "\0"
            hash.update(data: Data(info.utf8))
        }
        let kind = s.st_mode & S_IFMT
        if p != root && (excluded.contains(p) || s.st_dev != rootStat.st_dev) {
            result.nested = true; safe = false; return 0
        }
        var bytes = Int64(s.st_blocks) * 512
        if kind != S_IFDIR && s.st_nlink > 1 && !links.insert(Inode(device: s.st_dev, number: s.st_ino)).inserted { bytes = 0 }
        if kind == S_IFLNK {
            // A build with links is eligible only when the target remains in that build.
            if let candidate, !inside(canonical(p), candidate) || !fm.fileExists(atPath: p) { safe = false }
            return bytes
        }
        guard kind == S_IFDIR else { return bytes }
        if p != root && metadata(p + "/objects") != nil && metadata(p + "/HEAD") != nil {
            result.nested = true; safe = false; return 0
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: p) else { result.partial = true; safe = false; return bytes }
        let isBuild = candidate == nil && p != root && manifestMatches(p) && canonical(git(p, ["rev-parse","--show-toplevel"]).text) == root
        let current = isBuild ? p : candidate
        let nestedRepo = p != root && metadata(p + "/.git") != nil
        if nestedRepo { result.nested = true }
        var contentsSafe = !nestedRepo
        for entry in entries.sorted() {
            let child = p + "/" + entry
            if entry == ".git" && metadata(child).map({ $0.st_mode & S_IFMT == S_IFDIR }) == true {
                result.nested = true; contentsSafe = false; continue
            }
            let size = visit(child, candidate: current, safe: &contentsSafe)
            bytes += size
            if p == root && metadata(child).map({ $0.st_mode & S_IFMT == S_IFDIR }) == true {
                top.append(Folder(path: child, bytes: size))
            }
        }
        if isBuild && contentsSafe {
            let rel = String(p.dropFirst(root.count + 1))
            let tracked = git(root, ["ls-files","-z","--",rel])
            if tracked.code == 0 && tracked.data.isEmpty && git(root, ["check-ignore","-q","--","./" + rel + "/"]).code == 0 {
                result.builds.append(Folder(path: p, bytes: bytes))
            }
        }
        if !contentsSafe { safe = false }
        return bytes
    }
    var safe = true
    result.bytes = visit(root, candidate: nil, safe: &safe)
    result.folders = top.sorted { $0.bytes > $1.bytes }.prefix(8).map { $0 }
    result.stamp = fingerprint ? hash.finalize().map { String(format:"%02x",$0) }.joined() : ""
    return result
}
struct GitState: Codable, Equatable {
    var changes: [String] = []
    var statusOK = false
    var base: String?
    var contained: Bool?
    var created: Date?
    var active: Date?
    var source = "Desconhecida"
}
func gitState(_ tree: Tree) -> GitState {
    var state = GitState()
    let p = tree.path
    state.created = try? url(p).resourceValues(forKeys: [.creationDateKey]).creationDate
    let status = git(p, ["status","--porcelain=v1","-z","--untracked-files=all","--ignore-submodules=none"])
    state.statusOK = status.code == 0
    state.changes = status.fields
    let log = git(p, ["reflog","-1","--date=unix","--format=%gD","HEAD"])
    if let start = log.text.range(of:"@{"), let t = Double(log.text[start.upperBound...].prefix(while: { $0.isNumber })) {
        state.active = Date(timeIntervalSince1970: t); state.source = "Reflog do HEAD"
    }
    // Porcelain emits a second, unprefixed path for renames and copies.
    var oldPath = false
    for line in state.changes {
        if oldPath { oldPath = false; continue }
        oldPath = line.prefix(2).contains("R") || line.prefix(2).contains("C")
        let rel = String(line.dropFirst(3))
        if let s = metadata(p + "/" + rel) {
            let date = Date(timeIntervalSince1970: Double(s.st_mtimespec.tv_sec))
            if date > state.active ?? .distantPast { state.active = date; state.source = "Arquivo local modificado" }
        }
    }
    let remote = git(p, ["symbolic-ref","--short","refs/remotes/origin/HEAD"])
    let options = ([remote.code == 0 ? remote.text : ""] + ["origin/main","origin/master","main","master"]).filter { !$0.isEmpty }
    for base in options {
        let test = git(p, ["merge-base","--is-ancestor",tree.head,base])
        if [0,1].contains(test.code) { state.base = base; state.contained = test.code == 0; break }
    }
    return state
}
enum Action { case clean, remove }
struct Preview {
    let tree: Tree, disk: Measure, state: GitState, ignored: [String], durable: Bool
    var otherIgnored: [String] {
        ignored.filter { rel in
            !disk.builds.contains { inside((tree.path + "/" + rel).trimmingTrailingSlash, $0.path) }
        }
    }
}
extension String { var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self } }
func preview(_ expected: Tree, action: Action) throws -> Preview {
    let all = try listing(expected.main)
    guard let tree = all.first(where: { $0.path == expected.path }), tree == expected,
          !tree.missing, !tree.locked, canonical(tree.path) == tree.path,
          canonical(git(tree.path, ["rev-parse","--show-toplevel"]).text) == tree.path,
          metadata(tree.path + "/.git").map({ $0.st_mode & S_IFMT == S_IFREG }) == true else {
        throw Failure("Worktree alterado, ausente ou travado. Atualize o inventário.")
    }
    var links = Set<Inode>()
    let disk = measure(tree, excluded: Set(all.map(\.path)).subtracting([tree.path]), links: &links, fingerprint: true)
    let state = gitState(tree)
    guard state.statusOK, !disk.partial else { throw Failure("Leitura incompleta. Confira as permissões e atualize.") }
    let ignored = git(tree.path, ["ls-files","--others","--ignored","--exclude-standard","--directory","-z"])
    guard ignored.code == 0 else { throw Failure("Falha ao conferir arquivos ignorados.") }
    var durable = tree.branch != nil
    if !durable {
        let refs = git(tree.path, ["for-each-ref","--contains",tree.head,"--format=%(refname)","refs/heads","refs/tags","refs/remotes"])
        durable = refs.code == 0 && !refs.text.isEmpty
    }
    if action == .remove {
        guard durable else { throw Failure("HEAD destacado sem branch, tag ou referência remota que preserve o commit.") }
        guard state.changes.isEmpty else { throw Failure("Há alterações locais. Preserve-as antes de remover o worktree.") }
        guard !disk.nested else { throw Failure("O diretório contém outro repositório ou volume.") }
    }
    return Preview(tree: tree,disk: disk,state: state,ignored: ignored.fields.sorted(),durable: durable)
}
func execute(_ plan: Preview, action: Action, selection: Set<String>) throws -> String {
    let current = try preview(plan.tree, action: action)
    guard current.disk.stamp == plan.disk.stamp, current.state == plan.state, current.ignored == plan.ignored,
          current.disk.builds == plan.disk.builds else { throw Failure("O conteúdo mudou desde a prévia. Abra uma nova confirmação.") }
    if action == .remove {
        guard git(plan.tree.main, ["worktree","remove","--",plan.tree.path]).code == 0 else {
            throw Failure("O Git recusou a remoção. Confira o estado do worktree.")
        }
        return "Worktree removido. Branches preservadas."
    }
    guard !selection.isEmpty, selection.isSubset(of: Set(current.disk.builds.map(\.path))) else { throw Failure("Seleção de builds inválida.") }
    var removed = [String](), failed = [String]()
    for path in selection.sorted() {
        do {
            guard canonical(path) == path, inside(path, plan.tree.path) else { throw Failure("Caminho alterado.") }
            try fm.removeItem(atPath: path); removed.append(path)
        } catch { failed.append(path + " — " + error.localizedDescription) }
    }
    return (removed.map { "Limpo · " + $0 } + failed.map { "Pendente · " + $0 }).joined(separator:"\n")
}
