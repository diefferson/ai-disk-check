import SwiftUI

struct Mark: View {
    let name: String
    var side: CGFloat = 18
    var tint: Color? = nil
    private static let files = ["Claude":"claude-color","Codex":"codex-color","Copilot":"githubcopilot","Flutter":"flutter","Android":"android","Python":"python","Swift":"swift","Rust":"rust","Node.js":"nodejs","Aberto":"git-pull-request","Fechado":"git-pull-request-closed","Integrado":"git-merge","Branch":"git-branch"]
    private static let images = files.compactMapValues { file in
        Bundle.main.url(forResource:file,withExtension:"png",subdirectory:"Marks").flatMap(NSImage.init(contentsOf:))
    }
    var body: some View {
        Group {
            if let icon = Self.images[name] {
                Image(nsImage:icon).renderingMode(tint != nil || ["Rust","Copilot"].contains(name) ? .template : .original)
                    .resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName:name == "Todas" ? "square.grid.2x2.fill" : "square.dashed").resizable().scaledToFit()
            }
        }.frame(width:side,height:side).foregroundStyle(tint ?? .primary).accessibilityLabel(name)
    }
}
struct GitBadges: View {
    let row: Row
    var body: some View {
        let state = row.pull?.label ?? "A consultar"
        let number = row.pull?.number.map { " #" + String($0) } ?? ""
        HStack(spacing:5) {
            if ["Aberto","Integrado","Fechado"].contains(state) {
                Mark(name:state,side:15,tint:state == "Aberto" ? .green : state == "Integrado" ? .purple : .orange)
            } else {
                Image(systemName:state == "A consultar" ? "clock" : state == "Consulta indisponível" ? "wifi.slash" : state == "Associação ambígua" ? "questionmark.circle" : "minus.circle").foregroundStyle(.secondary)
            }
            if let n = row.pull?.number { Text("#" + String(n)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if row.state?.changes.isEmpty == false { Image(systemName:"pencil.circle.fill").foregroundStyle(.orange).accessibilityLabel("Alterações locais") }
        }.help(state + number + (row.state?.changes.isEmpty == false ? " · Alterações locais" : "")).accessibilityElement(children:.ignore)
            .accessibilityLabel(state + number + (row.state?.changes.isEmpty == false ? ", alterações locais" : ""))
    }
}
