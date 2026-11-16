import Foundation

struct Pull: Codable, Equatable {
    var label: String
    var link: URL?
    var number: Int?
    var ahead = false
}
struct RemotePull: Decodable {
    struct Head: Decodable {
        struct Repo: Decodable { let full_name: String }
        let sha: String
        let ref: String
        let repo: Repo?
    }
    let state: String
    let merged_at: String?
    let html_url: URL
    let number: Int
    let head: Head
}
func githubRepo(_ remote: String) -> String? {
    let prefixes = ["git@github.com:","https://github.com/","ssh://git@github.com/"]
    guard let prefix = prefixes.first(where: { remote.hasPrefix($0) }) else { return nil }
    var name = String(remote.dropFirst(prefix.count)).trimmingTrailingSlash
    if name.hasSuffix(".git") { name.removeLast(4) }
    guard name.range(of: #"^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$"#, options:.regularExpression) != nil else { return nil }
    return name
}
func pullStatus(_ tree: Tree, api: ([String]) -> Output = { args in
    let paths = ["/opt/homebrew/bin/gh","/usr/local/bin/gh"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy:":").map { $0 + "/gh" }
    guard let gh = paths.first(where: fm.isExecutableFile(atPath:)) else { return Output(code:-1,data:Data()) }
    return run(gh, ["api","--hostname","github.com"] + args, timeout:18)
}) -> Pull {
    func remote(_ name: String) -> String? { githubRepo(git(tree.path, ["remote","get-url","--",name]).text) }
    let tracking = tree.branch.map { git(tree.path, ["config","--get","branch." + $0 + ".remote"]).text }
    guard let origin = remote(tracking.flatMap { $0.isEmpty || $0 == "." ? nil : $0 } ?? "origin") else {
        return Pull(label:"Sem remoto GitHub")
    }
    let target = remote("upstream") ?? origin
    var args = ["repos/" + target]
    if let branch = tree.branch {
        args[0] += "/pulls"
        args += ["--method","GET","-f","state=all","-f","sort=updated","-f","head=" + String(origin.split(separator:"/")[0]) + ":" + branch]
    } else { args[0] += "/commits/" + tree.head + "/pulls" }
    let result = api(args)
    guard result.code == 0, let hits = try? JSONDecoder().decode([RemotePull].self,from:result.data) else {
        return Pull(label:"Consulta indisponível")
    }
    let matches = hits.filter { pr in
        guard let branch = tree.branch else { return true }
        return pr.head.ref == branch && pr.head.repo?.full_name.lowercased() == origin.lowercased()
    }
    guard !matches.isEmpty else { return Pull(label:"Nenhum PR encontrado") }
    let exact = matches.filter { $0.head.sha == tree.head }
    let choices = tree.branch == nil ? matches : (!exact.isEmpty ? exact : matches.filter { $0.state == "open" })
    let eligible = choices.isEmpty ? matches : choices
    guard eligible.count == 1, let pr = eligible.first else { return Pull(label:"Associação ambígua") }
    let ahead = pr.head.sha != tree.head && git(tree.path, ["merge-base","--is-ancestor",pr.head.sha,tree.head]).code == 0
    return Pull(label: pr.merged_at != nil ? "Integrado" : pr.state == "open" ? "Aberto" : "Fechado",
                link: pr.html_url,number:pr.number,ahead:ahead)
}
