import SwiftUI
import Charts
import AppKit

func size(_ n: Int64?) -> String {
    guard let n else { return "—" }
    let f = ByteCountFormatter()
    f.countStyle = .decimal
    return f.string(fromByteCount:n)
}
func when(_ date: Date?) -> String {
    guard let date else { return "Desconhecida" }
    return date.formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(Locale(identifier:"pt_BR")))
}
let ocean = Color(red:0.12,green:0.76,blue:0.64)
func tone(_ tool: String) -> Color {
    switch tool {
    case "Codex": return ocean
    case "Claude": return Color(red:0.94,green:0.58,blue:0.41)
    case "Copilot": return Color(red:0.61,green:0.57,blue:0.91)
    default: return .gray
    }
}
@main struct DiskApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("AI Disk Check",id:"inventory") {
            Dashboard(model:model)
                .environment(\.locale, Locale(identifier:"pt_BR"))
                .frame(minWidth:960,minHeight:640)
                .onAppear { model.refresh(); NSApp.activate(ignoringOtherApps:true) }
        }.defaultSize(width:1320,height:810)
    }
}
struct Dashboard: View {
    @ObservedObject var model: Model
    @State private var search = ""
    @State private var tool = "Todas"
    @State private var merged = false
    @State private var dirty = false
    @State private var settings = false
    @State private var selection = Set<String>()
    var filtered: [Row] {
        model.rows.values.filter { row in
            (tool == "Todas" || row.tool == tool) && (!merged || row.pull?.label == "Integrado") &&
            (!dirty || row.state?.changes.isEmpty == false) && (search.isEmpty ||
                [row.tree.path,row.tree.repo,row.tree.branch ?? ""].contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { ($0.disk?.bytes ?? -1, $0.id) > ($1.disk?.bytes ?? -1,$1.id) }
    }
    var body: some View {
        let list = filtered
        let selectedRows = list.filter { selection.contains($0.id) }
        HStack(spacing:0) {
            sidebar
            Divider()
            VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Armazenamento").font(.system(size:25,weight:.bold))
                Spacer()
                if model.scanning || model.operating {
                    ProgressView().controlSize(.small)
                    Text(model.operating ? "Conferindo worktree…" : model.phase).font(.caption).foregroundStyle(.secondary)
                }
                Button { model.refresh() } label: { Label("Atualizar",systemImage:"arrow.clockwise") }.disabled(model.scanning || model.operating)
            }
            Overview(rows:list,free:model.free) { tool = tool == $0 ? "Todas" : $0 }
            HStack {
                Toggle("PR integrado",isOn:$merged)
                Toggle("Alterações locais",isOn:$dirty)
                Spacer()
                TextField("Buscar repositório, branch ou caminho",text:$search).textFieldStyle(.roundedBorder).frame(maxWidth:310)
            }
            HStack {
                Text("Worktrees").font(.title2.bold())
                Text(String(list.count)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if selectedRows.count > 1 {
                    Text("\(selectedRows.count) selecionados").font(.callout)
                    Button("Limpar builds…") { model.prepare(selectedRows.map(\.tree),.clean) }
                    Button("Remover selecionados…",role:.destructive) { model.prepare(selectedRows.map(\.tree),.remove) }
                } else {
                    Text("⌘ + clique ou ⇧ + clique para selecionar vários").font(.caption).foregroundStyle(.secondary)
                }
            }
            HSplitView {
                Table(list,selection:$selection) {
                    TableColumn("Repositório / branch") { row in
                        VStack(alignment:.leading,spacing:3) {
                            HStack(spacing:5) {
                                Text(row.tree.repo).fontWeight(.semibold).lineLimit(1)
                                ForEach(Array((row.technologies ?? []).prefix(2)),id:\.self) { tech in
                                    Mark(name:tech,side:15).help(tech)
                                }
                            }
                            HStack(spacing:4) {
                                if row.tree.branch != nil { Mark(name:"Branch",side:11,tint:.secondary) }
                                else { Image(systemName:"circle.dotted").font(.caption2) }
                                Text(row.tree.branch ?? "HEAD destacado").lineLimit(1)
                            }.foregroundStyle(.secondary).font(.caption)
                        }.padding(.vertical,3).help(row.tree.path)
                    }.width(min:120,ideal:210)
                    TableColumn("Ferramenta") { row in Mark(name:row.tool,side:20).help(row.tool + " · " + (row.originReason ?? "A verificar")) }.width(min:60,ideal:72)
                    TableColumn("Em disco") { row in Text(size(row.disk?.bytes) + (row.disk?.partial == true ? "*" : "")).monospacedDigit() }.width(min:56,ideal:74)
                    TableColumn("Builds") { row in Text(size(row.disk?.buildBytes)).monospacedDigit() }.width(min:50,ideal:72)
                    TableColumn("Atividade") { row in Text(when(row.state?.active)).font(.caption) }.width(min:72,ideal:110)
                    TableColumn("Git / PR") { row in GitBadges(row:row) }.width(min:68,ideal:92)
                }.frame(minWidth:484)
                if selectedRows.count == 1, let row = selectedRows.first {
                    Inspector(row:row,model:model).frame(minWidth:245,idealWidth:295,maxWidth:350)
                }
            }.overlay {
                if list.isEmpty {
                    ContentUnavailableView(model.scanning ? "Procurando worktrees" : "Nenhum worktree nesta seleção",systemImage:"folder.badge.magnifyingglass",description:Text("Confira as pastas de busca e os filtros."))
                }
            }
            if let msg = model.issues.first { Text(msg).font(.caption).foregroundStyle(.secondary).help(model.issues.joined(separator:"\n")) }
        }.padding(20)
        }
        .onChange(of:list.map(\.id)) { _, visible in selection.formIntersection(visible) }
        .sheet(isPresented:Binding(get:{ model.batchReport != nil },set:{ if !$0 { model.batchReport = nil } })) {
            VStack(alignment:.leading,spacing:12) {
                Text("Resultado da operação").font(.title2.bold())
                ScrollView { Text((model.batchReport ?? []).joined(separator:"\n\n")).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                Button("Concluir") { model.batchReport = nil }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width:580,height:350)
        }
        .sheet(isPresented:$settings) { RootSettings(model:model) }
        .sheet(item:$model.confirmation) { sheet in ConfirmationView(sheet:sheet,model:model) }
        .alert("AI Disk Check",isPresented:Binding(get:{ model.alert != nil },set:{ if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }
    private var sidebar: some View {
        let counts = Dictionary(grouping:model.rows.values,by:\.tool).mapValues { $0.count }
        let names = ["Todas"] + Roots.tools.filter { $0 != "Outra" || counts[$0] != nil } + ["Desconhecida"]
        return VStack(alignment:.leading,spacing:5) {
            HStack(spacing:8) {
                Image(nsImage:NSApp.applicationIconImage).resizable().frame(width:32,height:32)
                Text("AI Disk Check").font(.headline)
            }.padding(.bottom,18)
            Text("Ferramentas").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,8)
            ForEach(names,id:\.self) { name in
                Button { tool = name } label: {
                    HStack(spacing:9) {
                        Mark(name:name,side:19)
                        Text(name == "Todas" ? "Todos os worktrees" : name).lineLimit(1)
                        Spacer(minLength:2)
                        Text(String(name == "Todas" ? model.rows.count : counts[name,default:0])).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(.horizontal,9).frame(height:34)
                        .background(tool == name ? Color.accentColor.opacity(0.20) : .clear,in:RoundedRectangle(cornerRadius:7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(tool == name ? .isSelected : [])
            }
            Spacer()
            Divider()
            Button { settings = true } label: { Label("Pastas de busca",systemImage:"folder.badge.gearshape") }
                .buttonStyle(.plain).padding(8)
        }.padding(12).frame(width:187).background(.regularMaterial)
    }
}
struct Overview: View {
    let rows: [Row], free: Int64?, choose: (String)->Void
    struct Group: Identifiable { let id: String, bytes: Int64 }
    var body: some View {
        let measured = rows.compactMap(\.disk)
        let total = measured.reduce(Int64(0)) { $0 + $1.bytes }
        let builds = measured.reduce(Int64(0)) { $0 + $1.buildBytes }
        let groups = Dictionary(grouping:rows,by:\.tool).map { Group(id:$0.key,bytes:$0.value.compactMap(\.disk).reduce(0){ $0 + $1.bytes }) }.sorted { $0.id < $1.id }
        let measuring = measured.isEmpty && !rows.isEmpty
        VStack(alignment:.leading,spacing:11) {
            HStack {
                Label("Worktrees na seleção",systemImage:"externaldrive.fill").font(.headline)
                Spacer()
                Text(size(measuring ? nil : total)).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Chart(groups) { group in
                BarMark(x:.value("Ocupação",group.bytes),y:.value("Seleção","Worktrees"),width:.ratio(1))
                    .foregroundStyle(tone(group.id)).accessibilityLabel(group.id).accessibilityValue(size(group.bytes))
            }.chartXScale(domain:0...max(1,total)).chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height:20).background(.quaternary).clipShape(RoundedRectangle(cornerRadius:5))
                .chartOverlay { proxy in GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { point in
                        guard let frame = proxy.plotFrame, let bytes: Int64 = proxy.value(atX:point.x - geo[frame].minX) else { return }
                        var end: Int64 = 0
                        for group in groups { end += group.bytes; if bytes < end { choose(group.id); return } }
                    }
                } }
            HStack(spacing:14) {
                ForEach(groups) { group in
                    Button { choose(group.id) } label: {
                        HStack(spacing:4) { Circle().fill(tone(group.id)).frame(width:8,height:8); Text(group.id) }
                    }.buttonStyle(.plain).help(group.id + " · " + size(group.bytes))
                }
            }.font(.caption)
            Divider()
            HStack {
                Label(size(measuring ? nil : builds) + " em builds",systemImage:"hammer")
                Spacer()
                Label(size(free) + " livres no volume pessoal",systemImage:"internaldrive")
            }.font(.callout).foregroundStyle(.secondary)
        }.padding(16).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
            .overlay { RoundedRectangle(cornerRadius:12).strokeBorder(.quaternary) }
    }
}
struct Inspector: View {
    let row: Row
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                HStack { Mark(name:row.tool,side:24); Text(row.tree.repo).font(.title3.bold()) }
                if let tech = row.technologies, !tech.isEmpty {
                    HStack { ForEach(tech,id:\.self) { Mark(name:$0,side:19).help($0) } }
                }
                Text(row.tree.branch ?? "HEAD destacado").textSelection(.enabled)
                Text(row.tree.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Abrir no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url(row.tree.path)]) }
                Divider()
                datum("Ferramenta · " + row.tool,row.originReason ?? "A verificar")
                datum("Criação estimada · pasta",when(row.state?.created))
                datum("Atividade · " + (row.state?.source ?? "desconhecida"),when(row.state?.active))
                datum("Última medição",when(row.disk?.measured))
                datum("Estado Git",row.tree.missing ? "Pasta ausente" : row.tree.locked ? "Travado" : row.state?.statusOK != true ? "Desconhecido" : row.state?.changes.isEmpty == true ? "Limpo" : "Com alterações locais")
                if let base = row.state?.base { datum("Base local · " + base,row.state?.contained == true ? "Contém o HEAD" : "Não contém o HEAD") }
                if let pr = row.pull, let link = pr.link {
                    Link("PR #" + String(pr.number ?? 0) + " · " + pr.label,destination:link)
                    if pr.ahead { Text("Há commits locais posteriores ao PR.").font(.caption) }
                } else { datum("Pull request",row.pull?.label ?? "A consultar") }
                Divider()
                Text("Maiores pastas").font(.headline)
                ForEach(row.disk?.folders ?? []) { folder in
                    HStack { Text(url(folder.path).lastPathComponent).lineLimit(1); Spacer(); Text(size(folder.bytes)).monospacedDigit() }.font(.caption)
                }
                if row.disk?.partial == true { Text("* Medição parcial por falha de leitura.").font(.caption) }
                Button("Limpar builds…") { model.prepare([row.tree],.clean) }.disabled(row.disk?.builds.isEmpty != false)
                Button("Remover worktree…",role:.destructive) { model.prepare([row.tree],.remove) }
            }.disabled(model.operating || row.tree.missing || row.tree.locked)
                .padding(.leading,14).padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    func datum(_ label:String,_ value:String) -> some View {
        VStack(alignment:.leading,spacing:2) { Text(label).foregroundStyle(.secondary).font(.caption); Text(value).font(.callout) }
    }
}
struct RootSettings: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) var dismiss
    @State private var tool = "Codex"
    func select(_ classification: String?) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let path = panel.url?.path { model.configure(path,tool:classification) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Pastas de busca").font(.title2.bold())
            ForEach(model.roots.paths,id:\.self) { Text($0).textSelection(.enabled) }
            Button("Adicionar pasta…") { select(nil) }
            Divider()
            Text("Classificar worktrees de uma pasta").font(.headline)
            ForEach(model.roots.rules.keys.sorted(),id:\.self) { path in Text(path + " · " + (model.roots.rules[path] ?? "")) }
            HStack { Picker("Ferramenta",selection:$tool) { ForEach(Roots.tools,id:\.self) { Text($0) } }
                Button("Escolher pasta…") { select(tool) } }
            HStack { Spacer(); Button("Concluir") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(minWidth:480)
    }
}
struct ConfirmationView: View {
    let sheet: WorktreeBatch
    @ObservedObject var model: Model
    @State private var selected: Set<String>
    init(sheet:WorktreeBatch,model:Model) {
        self.sheet = sheet; self.model = model
        _selected = State(initialValue:Set(sheet.plans.flatMap { $0.disk.builds.map(\.path) }))
    }
    var body: some View {
        let clean = sheet.action == .clean
        let discarding = !clean && sheet.plans.contains { !$0.state.changes.isEmpty }
        let backup = sheet.plans.contains { $0.backupBranch != nil }
        let removalTitle = backup ? "Criar branch de backup e remover" : "Apagar worktree"
        VStack(alignment:.leading,spacing:12) {
            Text(clean ? "Limpar builds" : "Remover worktrees").font(.title.bold())
            Text(sheet.plans.count == 1 ? "1 worktree elegível" : "\(sheet.plans.count) worktrees elegíveis").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(sheet.plans,id:\.tree.path) { plan in
                        details(plan, clean:clean)
                        Divider()
                    }
                    if !sheet.skipped.isEmpty {
                        Text("Fora da operação").font(.headline)
                        ForEach(sheet.skipped,id:\.self) { Text($0).font(.callout) }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text("A exclusão é permanente. Encerre os agentes e builds que estejam usando a pasta. O espaço recuperado em APFS pode variar.").font(.callout)
            HStack { Spacer(); Button("Cancelar") { model.confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(clean ? "Apagar builds selecionados" : (discarding ? "Apagar mesmo assim" : (sheet.plans.count > 1 ? "Remover worktrees selecionados" : removalTitle)),role:.destructive) {
                    model.apply(sheet,selection:selected,discardChanges:discarding)
                }.disabled(sheet.plans.isEmpty || (clean && selected.isEmpty)) }
        }.padding(24).frame(width:600,height:460)
    }
    @ViewBuilder private func details(_ plan: Preview, clean: Bool) -> some View {
        Text(plan.tree.path).font(.headline).textSelection(.enabled)
        Text((plan.tree.branch ?? "HEAD destacado") + " · PR: " + (model.rows[plan.tree.path]?.pull?.label ?? "Desconhecido"))
        if clean {
            ForEach(plan.disk.builds) { folder in
                Toggle(isOn:Binding(get:{ selected.contains(folder.path) },set:{ yes in
                    if yes { selected.insert(folder.path) } else { selected.remove(folder.path) }
                })) { Text(String(folder.path.dropFirst(plan.tree.path.count+1)) + " · " + size(folder.bytes)) }
            }
        } else {
            Text("Todo o conteúdo da pasta · " + size(plan.disk.bytes))
            if let backup = plan.backupBranch { Text("Backup do commit em " + backup).textSelection(.enabled) }
            if !plan.state.changes.isEmpty {
                Label("Alterações sem commit que serão perdidas",systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange)
                ForEach(plan.state.changes.indices,id:\.self) { Text(verbatim:plan.state.changes[$0]).font(.caption.monospaced()) }
            }
            if !plan.otherIgnored.isEmpty {
                Text("Arquivos e pastas ignorados fora dos builds").bold()
                ForEach(plan.otherIgnored,id:\.self) { Text($0).font(.caption.monospaced()) }
            }
            ForEach(plan.disk.builds) { Text("Build · " + $0.path) }
        }
    }
}
