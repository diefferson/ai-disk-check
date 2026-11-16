import Foundation

@main struct Acceptance {
    static func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw Failure("Teste falhou: " + message) }
    }
    static func refused(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure("Operação insegura foi aceita.")
    }
    static func main() throws {
        let base = canonical(fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        try fm.createDirectory(atPath:base,withIntermediateDirectories:true)
        defer { try? fm.removeItem(atPath:base) }
        try check(CreationHistory.destinations("git -C 'source repo' worktree add -b topic '../new task' main",cwd:base) == [canonical(base + "/new task")], "resolução de destino relativo")
        try check(CreationHistory.destinations("echo 'git worktree add /fake'",cwd:base).isEmpty, "menção não classifica")
        let history = url(base + "/history.jsonl")
        let call = #"{"cwd":"/tmp","message":{"content":[{"type":"tool_use","name":"Bash","id":"abc","input":{"command":"git worktree add --detach /tmp/fixture-wt"}}]}}"#
        func result(_ failed: Bool) throws -> Set<String> {
            let response = #"{"message":{"content":[{"type":"tool_result","tool_use_id":"abc","is_error":"# + String(failed) + "}]}}"
            try Data((call + "\n" + response).utf8).write(to:history)
            return CreationHistory.read(history,tool:"Claude")
        }
        try check(try result(true).isEmpty, "falha ao criar não atribui origem")
        try check(try result(false) == [canonical("/tmp/fixture-wt")], "resultado corresponde à chamada")
        let main = base + "/repos/source", work = base + "/outside/branch with spaces"
        func command(_ path:String,_ args:[String]) throws {
            try check(git(path,args).code == 0, "git " + args.joined(separator:" "))
        }
        func write(_ path:String,_ text:String) throws {
            try fm.createDirectory(at:url(path).deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(text.utf8).write(to:url(path))
        }
        try fm.createDirectory(atPath:main,withIntermediateDirectories:true)
        try command(main,["init","-b","main"])
        for pair in [["user.name","Fixture"],["user.email","test@example.invalid"],["commit.gpgsign","false"]] {
            try command(main,["config"] + pair)
        }
        try write(main + "/Package.swift","// fixture\n")
        try write(main + "/.gitignore",".build/\nbuild/\ntarget/\n.env\n")
        try command(main,["add","."]); try command(main,["commit","-m","init"])
        try command(main,["worktree","add","-b","task",work])
        var items = [Tree]()
        discover([base + "/repos",work],found:{ items.append($0) },issue:{ print($0) })
        try check(items.count == 1 && items[0].path == work,"descoberta externa e deduplicação")
        let tree = items[0]
        var index = OriginIndex(), config = Roots()
        index.creators[tree.path] = ["Claude","Codex"]
        try check(index.attribution(tree,roots:config).tool == "Desconhecida","conflito entre criadores")
        config.rules[tree.path] = "Copilot"
        try check(index.attribution(tree,roots:config).tool == "Copilot","prioridade da classificação manual")
        try write(work + "/.build/output",String(repeating:"abc12345",count:4000))
        try fm.linkItem(atPath:work + "/.build/output",toPath:work + "/.build/copy")
        try write(work + "/.env","example")
        try write(work + "/build/unrecognized","keep")
        try write(work + "/sub/Cargo.toml","[package]")
        try write(work + "/sub/target/bin","output")
        try write(work + "/app/pubspec.yaml","dependencies:\n  flutter:\n    sdk: flutter\n")
        try write(work + "/app/build/bin","output")
        try fm.createSymbolicLink(atPath:work + "/outside",withDestinationPath:main)
        var links = Set<Inode>()
        let disk = measure(tree,excluded:[],links:&links)
        let du = run("/usr/bin/du",["-sk",work])
        let kb = Int64(du.text.split(whereSeparator: { $0.isWhitespace }).first ?? "") ?? -1
        try check(!disk.partial && (disk.bytes+1023)/1024 == kb,"bytes alocados contra du: " + String(disk.bytes) + " vs " + String(kb))
        try check(disk.builds.count == 3,"manifestos de Swift, Flutter e Rust")
        try fm.createSymbolicLink(atPath:work + "/sub/target/escape",withDestinationPath:main)
        try write(work + "/app/build/tracked","source")
        try command(work,["add","-f","app/build/tracked"])
        try write(work + "/Package.swift","// user edit")
        let dirtyPlan = try preview(tree,action:.remove)
        try refused { _ = try execute(dirtyPlan,action:.remove,selection:[]) }
        let plan = try preview(tree,action:.clean)
        try check(plan.disk.builds.count == 1 && plan.disk.builds[0].path == work + "/.build","exclusão de links externos e arquivos rastreados")
        try check(plan.otherIgnored.contains(".env"),"prévia inclui .env")
        try write(work + "/.build/output","new data")
        try refused { _ = try execute(plan,action:.clean,selection:[work + "/.build"]) }
        let fresh = try preview(tree,action:.clean)
        _ = try execute(fresh,action:.clean,selection:[work + "/.build"])
        try check(!fm.fileExists(atPath:work + "/.build") && (try String(contentsOfFile:work + "/Package.swift",encoding:.utf8)) == "// user edit","edição preservada")
        try command(work,["add","."]); try command(work,["commit","-m","later"])
        let later = try listing(main)[0]
        try command(main,["remote","add","origin","git@github.com:demo/source.git"])
        func pr(_ state:String,_ merged:Bool) throws -> Pull {
            let record: [String:Any] = ["state":state,"merged_at":merged ? "2025-01-01" as Any : NSNull(),"html_url":"https://github.com/demo/source/pull/1","number":1,
                                        "head":["sha":tree.head,"ref":"task","repo":["full_name":"demo/source"]]]
            let data = try JSONSerialization.data(withJSONObject:[record])
            return pullStatus(later) { _ in Output(code:0,data:data) }
        }
        try check(try pr("open",false).label == "Aberto","PR aberto")
        try check(try pr("closed",false).label == "Fechado","PR fechado")
        let merged = try pr("closed",true)
        try check(merged.label == "Integrado" && merged.ahead && gitState(later).contained == false,"merge remoto independente e commits posteriores")
        try check(pullStatus(later) { _ in Output(code:1,data:Data()) }.label == "Consulta indisponível","offline")
        try check(pullStatus(later) { _ in Output(code:0,data:Data("[]".utf8)) }.label == "Nenhum PR encontrado","sem PR")
        let nested = work + "/nested"
        try command(main,["worktree","add","--detach",nested])
        links = []
        let withNested = measure(later,excluded:[nested],links:&links)
        try check(withNested.nested && withNested.folders.first(where:{ $0.path == nested })?.bytes == 0,"worktree aninhado")
        try command(main,["worktree","remove",nested])
        try command(main,["worktree","lock",work]); try refused { _ = try preview(later,action:.clean) }
        try command(main,["worktree","unlock",work])
        let snapshot = try preview(later,action:.remove)
        _ = try execute(snapshot,action:.remove,selection:[])
        try check(!fm.fileExists(atPath:work) && git(main,["show-ref","--verify","refs/heads/task"]).code == 0,"remoção preserva branch")
        try command(main,["worktree","add","--detach",work]); try command(work,["commit","--allow-empty","-m","detached"])
        let detached = try listing(main)[0]
        try command(main,["tag","preserved",detached.head])
        let protected = try preview(detached,action:.remove)
        try check(protected.backupBranch == nil,"tag já preserva HEAD")
        try command(main,["tag","-d","preserved"])
        try refused { _ = try execute(protected,action:.remove,selection:[]) }
        let recovery = try preview(detached,action:.remove)
        guard let backup = recovery.backupBranch else { throw Failure("Backup esperado para HEAD destacado.") }
        try command(main,["branch",backup,"main"])
        try refused { _ = try execute(recovery,action:.remove,selection:[]) }
        try check(fm.fileExists(atPath:work) && git(main,["rev-parse",backup]).text == git(main,["rev-parse","main"]).text,"colisão preserva pasta e branch existente")
        try write(work + "/Package.swift","staged")
        try command(work,["add","Package.swift"])
        try write(work + "/Package.swift","unstaged")
        try write(work + "/new.txt","untracked")
        let outdated = try preview(detached,action:.remove)
        try write(work + "/new.txt","changed after preview")
        try refused { _ = try execute(outdated,action:.remove,selection:[],discardChanges:true) }
        let retry = try preview(detached,action:.remove)
        guard let saved = retry.backupBranch else { throw Failure("Backup esperado na nova prévia.") }
        _ = try execute(retry,action:.remove,selection:[],discardChanges:true)
        try check(!fm.fileExists(atPath:work) && git(main,["rev-parse","refs/heads/" + saved]).text == detached.head,"backup preserva o commit exato após remoção")
        let second = base + "/second", locked = base + "/locked"
        for path in [work,second,locked] {
            try command(main,["worktree","add","--detach",path])
            try write(path + "/.build/output","build")
        }
        try command(main,["worktree","lock",locked])
        let group = try listing(main)
        let cleanBatch = WorktreeBatch(trees:group,action:.clean)
        try check(cleanBatch.plans.count == 2 && cleanBatch.skipped.count == 1,"prévia distingue o worktree travado")
        _ = cleanBatch.run(builds:[work + "/.build",second + "/.build"],discardChanges:false)
        try check(!fm.fileExists(atPath:work + "/.build") && !fm.fileExists(atPath:second + "/.build") && fm.fileExists(atPath:locked + "/.build/output"),"limpeza em lote respeita bloqueio")
        let removeBatch = WorktreeBatch(trees:group,action:.remove)
        try write(work + "/new.txt","edição posterior à prévia")
        let outcomes = removeBatch.run(builds:[],discardChanges:false)
        try check(outcomes.count == 3 && fm.fileExists(atPath:work + "/new.txt") && !fm.fileExists(atPath:second) && fm.fileExists(atPath:locked),"remoção em lote continua após falha individual")
        let store = try Store(directory:url(base + "/cache"))
        try store.save("sample",items); try check(store.read("sample",as:[Tree].self) == items,"SQLite")
        print("OK · inventário, du, builds, Git, PRs simulados, limpeza, revalidação e SQLite")
        for repo in CommandLine.arguments.dropFirst() {
            var actual = [Tree]()
            discover([repo],found:{ actual.append($0) },issue:{ print($0) })
            let list = git(repo,["worktree","list","--porcelain"])
            let lines = list.text.components(separatedBy:"\n").filter { $0.hasPrefix("worktree ") }.dropFirst()
            let paths = Set(lines.map { canonical(String($0.dropFirst(9))) })
            try check(list.code == 0 && Set(actual.map(\.path)) == paths && actual.count == paths.count,"inventário real: " + repo)
            print("OK · " + url(repo).lastPathComponent + ": " + String(paths.count) + " worktrees correspondem ao Git")
        }
    }
}
