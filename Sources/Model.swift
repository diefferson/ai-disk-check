import AppKit
import SwiftUI

@MainActor final class Model: ObservableObject {
    @Published var rows = [String:Row]()
    @Published var roots = Roots()
    @Published var scanning = false
    @Published var phase = ""
    @Published var issues = [String]()
    @Published var free: Int64?
    @Published var alert: String?
    @Published var operating = false
    @Published var confirmation: Confirmation?
    var job: Task<Void,Never>?
    private var refreshPending = false
    private var changedDuringScan = Set<String>()
    var store: Store?
    struct Confirmation: Identifiable {
        let id = UUID()
        let plan: Preview, action: Action
    }
    init() {
        do {
            let directory = try fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            store = try Store(directory:directory.appendingPathComponent("AI Disk Check"))
            if let config = store?.read("roots",as:Roots.self) { roots = config }
            rows = store?.read("rows",as:[String:Row].self) ?? [:]
        } catch { alert = error.localizedDescription }
    }
    func save<T: Encodable>(_ key: String,_ value: T) {
        do { try store?.save(key,value) } catch { alert = error.localizedDescription }
    }
    func refresh() {
        guard !scanning, !operating else { return }
        scanning = true; changedDuringScan = []; issues = []; phase = "Localizando worktrees…"
        free = (try? url(NSHomeDirectory()).resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
        let config = roots
        var paths = config.paths + Array(config.rules.keys)
        if let template = config.copilotTemplate, template.hasPrefix("/") {
            let prefix = String(template.prefix(while: { $0 != "{" }))
            let base = prefix.hasSuffix("/") ? prefix.trimmingTrailingSlash : url(prefix).deletingLastPathComponent().path
            if !base.isEmpty && base != "/" && base != NSHomeDirectory() { paths.append(base) }
        }
        let search = paths
        job = Task {
            let previous = store?.read("originFiles",as:[String:HistoryFile].self) ?? [:]
            let history = Task.detached(priority:.utility) { OriginIndex(previous:previous) }
            enum Event { case item(Tree,[String]), error(String) }
            let stream = AsyncStream<Event> { stream in
                DispatchQueue.global(qos:.utility).async {
                    discover(search,found:{ stream.yield(.item($0,$0.missing ? [] : projectTechnologies(at:$0.path))) },issue:{ stream.yield(.error($0)) })
                    stream.finish()
                }
            }
            var seen = Set<String>()
            for await event in stream {
                switch event {
                case .item(let tree, let technologies):
                    seen.insert(tree.path)
                    var row = rows[tree.path] ?? Row(tree:tree,tool:config.tool(tree.path))
                    if row.tree != tree { row.state = nil; row.pull = nil }
                    row.tree = tree
                    row.technologies = technologies
                    rows[tree.path] = row
                case .error(let msg): if issues.count < 20 { issues.append(msg) }
                }
            }
            rows = rows.filter { seen.contains($0.key) }
            phase = "Identificando ferramentas…"
            let index = await history.value
            for path in seen {
                guard var row = rows[path] else { continue }
                let origin = index.attribution(row.tree,roots:config)
                row.tool = origin.tool; row.originReason = origin.reason
                rows[path] = row
            }
            save("originFiles",index.files)
            save("rows",rows)
            let items = rows.values.map(\.tree).filter { !$0.missing }.sorted { $0.path < $1.path }
            let excluded = Set(items.map(\.path))
            phase = "Medindo pastas e consultando PRs…"
            async let prs: Void = updatePRs(items)
            var links = Set<Inode>()
            for (index, tree) in items.enumerated() {
                let previous = links
                let (disk,state,next) = await Task.detached(priority:.utility) {
                    var shared = previous
                    return (measure(tree,excluded:excluded.subtracting([tree.path]),links:&shared),gitState(tree),shared)
                }.value
                links = next
                if !changedDuringScan.contains(tree.path) {
                    rows[tree.path]?.disk = disk; rows[tree.path]?.state = state
                }
                if index % 12 == 0 { save("rows",rows) }
            }
            save("rows",rows)
            await prs
            save("rows",rows)
            scanning = false; phase = ""
            if refreshPending { refreshPending = false; refresh() }
        }
    }
    private func updatePRs(_ items:[Tree]) async {
        for tree in items {
            let pull = await Task.detached(priority:.utility) { pullStatus(tree) }.value
            rows[tree.path]?.pull = pull
        }
    }
    func configure(_ scope: String, tool: String?) {
        let path = canonical(scope)
        if let tool { roots.rules[path] = tool }
        else if !roots.paths.contains(path) { roots.paths.append(path) }
        save("roots",roots)
        if scanning { refreshPending = true } else { refresh() }
    }
    func prepare(_ tree: Tree, _ action: Action) {
        operating = true
        Task {
            do {
                let plan = try await Task.detached(priority:.userInitiated) { try preview(tree,action:action) }.value
                if action == .clean && plan.disk.builds.isEmpty { throw Failure("Nenhum build elegível para limpeza.") }
                confirmation = Confirmation(plan:plan,action:action)
            } catch { alert = error.localizedDescription }
            operating = false
        }
    }
    func apply(_ sheet: Confirmation, selection: Set<String>, discardChanges: Bool) {
        confirmation = nil; operating = true
        Task {
            do {
                alert = try await Task.detached(priority:.userInitiated) { try execute(sheet.plan,action:sheet.action,selection:selection,discardChanges:discardChanges) }.value
            } catch { alert = error.localizedDescription }
            let tree = sheet.plan.tree
            changedDuringScan.insert(tree.path)
            if metadata(tree.path) == nil {
                rows.removeValue(forKey: tree.path)
            } else {
                let excluded = Set(rows.keys).subtracting([tree.path])
                let (disk, state) = await Task.detached(priority:.utility) {
                    var links = Set<Inode>()
                    return (measure(tree,excluded:excluded,links:&links), gitState(tree))
                }.value
                rows[tree.path]?.disk = disk
                rows[tree.path]?.state = state
            }
            free = (try? url(NSHomeDirectory()).resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
            save("rows",rows)
            operating = false
            if scanning { refreshPending = true } else { refresh() }
        }
    }
}
