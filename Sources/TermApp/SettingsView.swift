import SwiftUI
import TermTranscript
import UniformTypeIdentifiers

enum SettingsCatalog {
    struct Entry {
        let page: String
        let title: String
        let detail: String
    }

    static let entries: [(id: String, entry: Entry)] = [
        ("style", Entry(page: "appearance", title: "Style", detail: "Modern adds space around text, softer box lines, a translucent window, a gliding cursor and smooth scrolling. Classic is compact, opaque and crisp.")),
        ("opacity", Entry(page: "appearance", title: "Background opacity", detail: "How much of the desktop shows through the window.")),
        ("letterSpacing", Entry(page: "appearance", title: "Letter spacing", detail: "Extra room between characters.")),
        ("mode", Entry(page: "appearance", title: "Mode", detail: "Light, dark, or follow the system.")),
        ("lightTheme", Entry(page: "appearance", title: "Light theme", detail: "Terminal colours in light mode.")),
        ("darkTheme", Entry(page: "appearance", title: "Dark theme", detail: "Terminal colours in dark mode.")),
        ("importColours", Entry(page: "appearance", title: "iTerm2 colours", detail: "Import .itermcolors files as custom themes.")),
        ("font", Entry(page: "text", title: "Font", detail: "Any monospaced font installed on this Mac.")),
        ("fontSize", Entry(page: "text", title: "Size", detail: "Text size in points.")),
        ("lineSpacing", Entry(page: "text", title: "Line spacing", detail: "Space between lines, as a multiple of the font's height.")),
        ("thinStrokes", Entry(page: "text", title: "Thin strokes", detail: "Draws text without macOS font smoothing, which otherwise makes it look heavier.")),
        ("hideAgentInput", Entry(page: "text", title: "One place to type", detail: "Hides the agent's own input box while the composer is open. Questions and menus from the agent still show in the terminal.")),
        ("statusStyle", Entry(page: "text", title: "Status line", detail: "Native redraws the agent's status line as labels and meters under the composer.")),
        ("editor", Entry(page: "text", title: "Open file paths in", detail: "Hold Command over a path or link and click to open it. Paths like src/app.ts:42 open at that line.")),
        ("cursorShape", Entry(page: "text", title: "Cursor shape", detail: "Block, bar or underline.")),
        ("cursorBlink", Entry(page: "text", title: "Blinking cursor", detail: "The cursor blinks while the window is active.")),
        ("optionKey", Entry(page: "keyboard", title: "Option key", detail: "Meta sends Escape before the key, which shells and editors use for word movement and shortcuts.")),
        ("naturalText", Entry(page: "keyboard", title: "Natural text editing", detail: "Option-arrows move by word, Command-arrows go to the line's start and end, Option-Delete deletes a word.")),
        ("keyBindings", Entry(page: "keyboard", title: "Key bindings", detail: "Send text or an escape sequence (\\e for Escape, \\r, \\n, \\t, \\xHH) from a key.")),
        ("quickTerminal", Entry(page: "keyboard", title: "Quick Terminal", detail: "A hotkey that drops a terminal down from the top of the screen over any app.")),
        ("startFolder", Entry(page: "windows", title: "New windows open in", detail: "The folder a new window starts in.")),
        ("restore", Entry(page: "windows", title: "Reopen windows and tabs", detail: "Brings back your windows and tabs when Terminess starts.")),
        ("keepSessions", Entry(page: "windows", title: "Keep sessions running", detail: "Shells and agents keep running after Terminess quits, and reattach when it reopens. Applies to new tabs.")),
        ("tabsInFolder", Entry(page: "windows", title: "New tabs use the current folder", detail: "A new tab opens in the folder of the tab you're in.")),
        ("shellIntegration", Entry(page: "windows", title: "Shell integration (zsh)", detail: "Marks prompts and commands, to jump between prompts, copy the last output and hear when long commands finish. Your dotfiles aren't changed.")),
        ("scrollback", Entry(page: "windows", title: "Scrollback", detail: "Lines each tab keeps. Applies to new tabs.")),
        ("parking", Entry(page: "windows", title: "Park idle agent tabs", detail: "Claude Code and Codex tabs left idle in the background stop to free memory, and resume the same conversation when you switch back.")),
        ("parkingAfter", Entry(page: "windows", title: "Park after", detail: "How long a tab is idle before it's parked.")),
        ("pairSkill", Entry(page: "agents", title: "Pair skill", detail: "Lets Claude Code and Codex hand work to each other and ask for reviews.")),
        ("agentTools", Entry(page: "agents", title: "Terminess tools", detail: "Gives the agents Terminess's own tools, such as reminders.")),
        ("apiKey", Entry(page: "agents", title: "Anthropic API key", detail: "For Terminess agent tabs, billed to your own Anthropic account.")),
        ("localModels", Entry(page: "agents", title: "Local models on", detail: "Shell, Local Model lists the Ollama models on this Mac or an SSH host, and opens a tab chatting with one.")),
        ("preferredAgent", Entry(page: "agents", title: "Agent for Terminess jobs", detail: "Which agent runs the jobs Terminess starts for you.")),
        ("opsGuide", Entry(page: "agents", title: "Operations guide", detail: "OPERATIONS.md and ORCHESTRATE.md tell every agent how your setup is built and how to work here.")),
        ("modelRoles", Entry(page: "models", title: "Models", detail: "Which model each agent uses for orchestration, building, reviews and handed-off work.")),
        ("machines", Entry(page: "machines", title: "Machines", detail: "Servers and other computers running terminessd, whose sessions show in the sidebar.")),
        ("systemNotifications", Entry(page: "notifications", title: "Banners and sounds", detail: "Terminess tells you when an agent needs you or finishes, and when a long command ends. Choose how in System Settings.")),
        ("agentEvents", Entry(page: "notifications", title: "Agent reports", detail: "Let Claude Code and Codex tell Terminess when they're working, finished or need you. Needs Keep sessions running, in Windows.")),
        ("updates", Entry(page: "privacy", title: "Updates", detail: "Terminess never checks on its own. It asks terminess.com only when you choose Check for Updates.")),
        ("pairedPhones", Entry(page: "privacy", title: "Paired iPhones", detail: "Phones that can follow and steer this Mac's sessions. Each one holds its own key, which you can remove.")),
        ("history", Entry(page: "privacy", title: "Past conversations", detail: "Read from the agents' own folders on this Mac, and listed only for the agents you import.")),
    ]

    static func entry(_ id: String) -> Entry {
        entries.first { $0.id == id }?.entry ?? Entry(page: "", title: id, detail: "")
    }

    static func search(_ query: String) -> [(id: String, entry: Entry)] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { e in
            let hay = "\(e.entry.title) \(e.entry.detail) \(SettingsPages.label(e.entry.page))".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

enum SettingsPages {
    static let all: [(id: String, label: String, symbol: String)] = [
        ("appearance", "Appearance", "paintpalette"),
        ("text", "Text", "textformat"),
        ("keyboard", "Keyboard", "keyboard"),
        ("windows", "Windows", "macwindow.on.rectangle"),
        ("agents", "Agents", "sparkles"),
        ("models", "Models", "cpu"),
        ("machines", "Machines", "server.rack"),
        ("notifications", "Notifications", "bell"),
        ("privacy", "Privacy", "hand.raised"),
    ]
    static func label(_ id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

struct SettingRow<Control: View>: View {
    let id: String
    @ViewBuilder var control: Control

    init(_ id: String, @ViewBuilder control: () -> Control) {
        self.id = id
        self.control = control()
    }

    var body: some View {
        let e = SettingsCatalog.entry(id)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title)
                if !e.detail.isEmpty {
                    Text(e.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.labelsHidden().fixedSize()
        }
    }
}

struct SettingsPane: View {
    @AppStorage("settingsPage") private var page = "appearance"
    @State private var query = ""
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search settings", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 9).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                .padding(.bottom, 8)
                ForEach(SettingsPages.all, id: \.id) { p in
                    let matches = query.isEmpty || SettingsCatalog.search(query).contains { $0.entry.page == p.id }
                    Button { page = p.id; query = "" } label: {
                        HStack(spacing: 9) {
                            Image(systemName: p.symbol).font(.system(size: 13)).frame(width: 18)
                                .foregroundStyle(page == p.id && query.isEmpty ? .primary : .secondary)
                            Text(p.label).font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.horizontal, 9).frame(height: 30)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(page == p.id && query.isEmpty ? Color.primary.opacity(0.08) : .clear))
                    }
                    .buttonStyle(.plain)
                    .opacity(matches ? 1 : 0.4)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 214)
            .background(Color(nsColor: .sidebarPane))

            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)

            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(query.isEmpty ? SettingsPages.label(page) : "Results")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 2)
                    if query.isEmpty {
                        SettingsPageContent(page: page)
                    } else {
                        results
                    }
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Settings (Esc)")
                .keyboardShortcut(.cancelAction)
                .padding(.top, 14).padding(.trailing, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .noTopScrollEdge()
    }

    private var results: some View {
        let found = SettingsCatalog.search(query)
        return Form {
            if found.isEmpty {
                Text("No settings match \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
            }
            ForEach(found, id: \.id) { r in
                Button { page = r.entry.page; query = "" } label: {
                    LabeledContent {
                        Text(SettingsPages.label(r.entry.page)).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.entry.title)
                            Text(r.entry.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

final class SettingsHostView: NSHostingView<SettingsPane> {}

struct SettingsView: View {
    @AppStorage("settingsPage") private var page = "appearance"
    static var pages: [(String, String)] { SettingsPages.all.map { ($0.id, $0.label) } }

    var body: some View {
        SettingsPageContent(page: page)
            .frame(width: SettingsWindowController.width)
            .frame(minHeight: 360, maxHeight: .infinity)
    }
}

struct SettingsPageContent: View {
    let page: String
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var sidebar = SidebarModel.shared
    @State private var editing: Theme?
    @State private var editingForDark = true
    @State private var addingBinding = false
    private let fonts = Settings.monospacedFonts()

    var body: some View {
        Form {
            switch page {
            case "appearance": appearance
            case "text": text
            case "keyboard": keyboard
            case "windows": windows
            case "agents": agents
            case "models": ModelRolesSection()
            case "machines": MachinesSection()
            case "notifications": notifications
            case "privacy": privacy
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $addingBinding) {
            BindingRecorder { b in
                settings.keyBindings.append(b)
                addingBinding = false
            } onCancel: { addingBinding = false }
        }
        .sheet(item: $editing) { theme in
            ThemeEditor(theme: theme) { saved in
                settings.saveCustom(saved)
                if editingForDark { settings.darkTheme = saved.name } else { settings.lightTheme = saved.name }
                editing = nil
            } onCancel: { editing = nil }
        }
    }


    @ViewBuilder private var appearance: some View {
        Section {
            SettingRow("style") {
                Picker("Style", selection: $settings.style) {
                    Text("Modern").tag("modern")
                    Text("Classic").tag("classic")
                }
                .pickerStyle(.segmented).fixedSize()
            }
            if settings.isModern {
                SettingRow("opacity") {
                    HStack {
                        Slider(value: $settings.backgroundOpacity, in: 0.6...1.0, step: 0.02).frame(width: 140)
                        Text("\(Int(settings.backgroundOpacity * 100))%").foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingRow("letterSpacing") {
                    HStack {
                        Slider(value: $settings.letterSpacing, in: 0...1.5, step: 0.1).frame(width: 140)
                        Text(String(format: "%.1f", settings.letterSpacing)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        Section {
            SettingRow("mode") {
                Picker("Mode", selection: $settings.appearance) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            SettingRow("lightTheme") {
                ThemePicker(title: "Light theme", selection: $settings.lightTheme, themes: settings.allThemes) {
                    edit(settings.theme(named: settings.lightTheme, fallbackDark: false), forDark: false)
                }
            }
            SettingRow("darkTheme") {
                ThemePicker(title: "Dark theme", selection: $settings.darkTheme, themes: settings.allThemes) {
                    edit(settings.theme(named: settings.darkTheme, fallbackDark: true), forDark: true)
                }
            }
            SettingRow("importColours") {
                HStack {
                    if !settings.customThemes.isEmpty {
                        Menu("Delete…") {
                            ForEach(settings.customThemes) { t in
                                Button(t.name) { settings.deleteCustom(t.name) }
                            }
                        }
                        .fixedSize()
                    }
                    Button("Import…", action: importITerm)
                }
            }
        }
    }

    @ViewBuilder private var text: some View {
        Section {
            SettingRow("font") {
                Picker("Font", selection: $settings.fontName) {
                    Text("SF Mono (system)").tag("")
                    Divider()
                    ForEach(fonts, id: \.1) { family, ps in
                        Text(family).tag(ps)
                    }
                }
                .fixedSize()
            }
            SettingRow("fontSize") {
                Stepper(value: $settings.fontSize, in: 8...36, step: 1) {
                    Text("\(Int(settings.fontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                }
                .fixedSize()
            }
            SettingRow("lineSpacing") {
                HStack {
                    Slider(value: $settings.lineSpacing, in: 1.0...1.6, step: 0.05).frame(width: 140)
                    Text(String(format: "%.2f", settings.lineSpacing)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
            SettingRow("thinStrokes") { Toggle("Thin strokes", isOn: $settings.thinStrokes).toggleStyle(.switch) }
        }
        Section("Composer") {
            SettingRow("hideAgentInput") {
                Toggle("One place to type", isOn: $settings.composerHidesAgentInput).toggleStyle(.switch)
            }
            SettingRow("statusStyle") {
                Picker("Status line", selection: $settings.statusStyle) {
                    Text("Native").tag("native")
                    Text("As in the terminal").tag("terminal")
                }
                .fixedSize()
            }
        }
        Section("Links and cursor") {
            SettingRow("editor") {
                Picker("Open file paths in", selection: $settings.editor) {
                    ForEach(Editor.choices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .fixedSize()
            }
            SettingRow("cursorShape") {
                Picker("Shape", selection: $settings.cursorShape) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                .pickerStyle(.segmented).fixedSize()
            }
            SettingRow("cursorBlink") { Toggle("Blink", isOn: $settings.cursorBlink).toggleStyle(.switch) }
        }
    }

    @ViewBuilder private var keyboard: some View {
        Section {
            SettingRow("optionKey") {
                Picker("Option key", selection: $settings.optionKey) {
                    Text("Left Option is Meta").tag("left")
                    Text("Both are Meta").tag("both")
                    Text("Normal").tag("none")
                }
                .fixedSize()
            }
            SettingRow("naturalText") {
                Toggle("Natural text editing", isOn: $settings.naturalTextEditing).toggleStyle(.switch)
            }
            SettingRow("quickTerminal") {
                Picker("Hotkey", selection: $settings.quickTerminalKey) {
                    Text("Off").tag("off")
                    ForEach(QuickTerminal.choices, id: \.0) { choice in
                        Text(choice.1).tag(choice.0)
                    }
                }
                .fixedSize()
            }
        }
        Section {
            SettingRow("keyBindings") {
                Button("Add…") { addingBinding = true }
            }
            ForEach(settings.keyBindings) { b in
                HStack {
                    Text(b.label).monospaced().frame(width: 80, alignment: .leading)
                    Text(b.text).monospaced().foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { settings.keyBindings.removeAll { $0.id == b.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private var windows: some View {
        Section {
            SettingRow("startFolder") {
                HStack {
                    Text(settings.startFolder.isEmpty ? "Home folder" : abbreviate(settings.startFolder))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !settings.startFolder.isEmpty {
                        Button("Reset") { settings.startFolder = "" }
                    }
                    Button("Choose…", action: chooseFolder)
                }
            }
            SettingRow("restore") { Toggle("Reopen", isOn: $settings.restoreSession).toggleStyle(.switch) }
            SettingRow("keepSessions") { Toggle("Keep running", isOn: $settings.keepSessions).toggleStyle(.switch) }
            SettingRow("tabsInFolder") { Toggle("Current folder", isOn: $settings.newTabsInCurrentFolder).toggleStyle(.switch) }
            SettingRow("shellIntegration") { Toggle("Shell integration", isOn: $settings.shellIntegration).toggleStyle(.switch) }
            SettingRow("scrollback") {
                Picker("Scrollback", selection: $settings.scrollback) {
                    Text("1,000 lines").tag(1_000)
                    Text("10,000 lines").tag(10_000)
                    Text("50,000 lines").tag(50_000)
                    Text("100,000 lines").tag(100_000)
                }
                .fixedSize()
            }
        }
        Section("Memory") {
            SettingRow("parking") { Toggle("Park", isOn: $settings.idleParking).toggleStyle(.switch) }
            SettingRow("parkingAfter") {
                Picker("After", selection: $settings.idleParkingMinutes) {
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
                .fixedSize()
                .disabled(!settings.idleParking)
            }
        }
    }

    @ViewBuilder private var agents: some View {
        Section("Skills and tools") {
            PairSkillToggle(agent: .claude)
            PairSkillToggle(agent: .codex)
            AgentToolsToggle(agent: .claude)
            AgentToolsToggle(agent: .codex)
        }
        Section {
            AgentKeyField()
            SettingRow("localModels") {
                TextField("Local models on", text: $settings.localModelsHost, prompt: Text("This Mac, or an SSH host"))
                    .frame(width: 200)
            }
            SettingRow("preferredAgent") {
                Picker("Agent for Terminess jobs", selection: $settings.preferredAgent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                .fixedSize()
            }
            SettingRow("opsGuide") { Button("Open…") { OpsGuideWindow.show() } }
        }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            SettingRow("systemNotifications") {
                Button("Open System Settings…") {
                    let id = Bundle.main.bundleIdentifier ?? ""
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        Section("Agent reports") {
            AgentEventsToggle(agent: .claude).disabled(!settings.keepSessions)
            AgentEventsToggle(agent: .codex).disabled(!settings.keepSessions)
            if !settings.keepSessions {
                Text("Turn on Keep sessions running, in Windows, to use these.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var privacy: some View {
        Section {
            SettingRow("updates") {
                Button("Check Now") {
                    NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
                }
            }
            SettingRow("pairedPhones") {
                HStack {
                    Text(sidebar.hasPairedPhone ? "Paired" : "None").foregroundStyle(.secondary)
                    Button(sidebar.hasPairedPhone ? "Manage…" : "Pair iPhone…") {
                        NSApp.sendAction(#selector(AppDelegate.showPairPhone(_:)), to: nil, from: nil)
                    }
                }
            }
            SettingRow("history") {
                Text(sidebar.importedAgents.isEmpty ? "None imported"
                     : HistoryImport.agents.filter { sidebar.importedAgents.contains($0) }.map(HistoryImport.name).joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
    }


    private func edit(_ theme: Theme, forDark: Bool) {
        var t = theme
        if t.builtIn { t.name = "\(t.name) (Custom)"; t.builtIn = false }
        editingForDark = forDark
        editing = t
    }

    private func abbreviate(_ path: String) -> String {
        let home = Transcript.home
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { settings.startFolder = url.path }
    }

    private func importITerm() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "itermcolors") ?? .data]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let t = Theme.importITerm(url) { settings.saveCustom(t) }
        }
    }
}


private struct ThemePicker: View {
    let title: String
    @Binding var selection: String
    let themes: [Theme]
    let onEdit: () -> Void

    var body: some View {
        HStack {
            Picker(title, selection: $selection) {
                ForEach(themes) { t in
                    Text(t.name).tag(t.name)
                }
            }
            if let t = themes.first(where: { $0.name == selection }) {
                Swatch(theme: t)
            }
            Button("Edit…", action: onEdit)
        }
    }
}

private struct Swatch: View {
    let theme: Theme
    var body: some View {
        HStack(spacing: 2) {
            Text("Aa").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: Theme.color(theme.foreground)))
            ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                Circle().fill(Color(nsColor: Theme.color(theme.ansi[i]))).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Theme.color(theme.background))))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 0.5))
    }
}

private struct ThemeEditor: View {
    @State var theme: Theme
    let onSave: (Theme) -> Void
    let onCancel: () -> Void

    private static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $theme.name)
                Section("Base") {
                    colorRow("Background", \.background)
                    colorRow("Text", \.foreground)
                    colorRow("Cursor", \.cursor)
                    colorRow("Selection", \.selection)
                }
                Section("ANSI colours") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("")
                            Text("Normal").font(.caption).foregroundStyle(.secondary)
                            Text("Bright").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(0..<8, id: \.self) { i in
                            GridRow {
                                Text(Self.ansiNames[i])
                                ColorPicker("", selection: ansiBinding(i), supportsOpacity: false).labelsHidden()
                                ColorPicker("", selection: ansiBinding(i + 8), supportsOpacity: false).labelsHidden()
                            }
                        }
                    }
                }
                Section("Preview") {
                    preview
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(theme) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(theme.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || Theme.builtIns.contains { $0.name == theme.name })
            }
            .padding()
        }
        .frame(width: 440, height: 640)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("~/github % ").foregroundStyle(c(theme.ansi[2]))
                Text("git status").foregroundStyle(c(theme.foreground))
            }
            HStack(spacing: 6) {
                ForEach(1..<7, id: \.self) { i in Text("■").foregroundStyle(c(theme.ansi[i])) }
                ForEach(9..<15, id: \.self) { i in Text("■").foregroundStyle(c(theme.ansi[i])) }
            }
            Text(" selected text ").foregroundStyle(c(theme.foreground)).background(c(theme.selection))
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(c(theme.background)))
    }

    private func c(_ hex: String) -> Color { Color(nsColor: Theme.color(hex)) }

    private func colorRow(_ label: String, _ key: WritableKeyPath<Theme, String>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(nsColor: Theme.color(theme[keyPath: key])) },
            set: { theme[keyPath: key] = Theme.hex(NSColor($0)) }), supportsOpacity: false)
    }

    private func ansiBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { Color(nsColor: Theme.color(theme.ansi[i])) },
                set: { theme.ansi[i] = Theme.hex(NSColor($0)) })
    }
}

private struct BindingRecorder: View {
    let onSave: (KeyBinding) -> Void
    let onCancel: () -> Void
    @State private var key: String?
    @State private var modifiers = 0
    @State private var text = ""
    @State private var monitor: Any?
    @State private var recording = false

    var body: some View {
        Form {
            HStack {
                Text("Shortcut")
                Spacer()
                Button(recording ? "Press keys…" : (key.map { KeyBinding(key: $0, modifiers: modifiers, text: "").label } ?? "Record")) {
                    startRecording()
                }
            }
            TextField("Send", text: $text, prompt: Text("e.g. \\eb"))
                .monospaced()
            HStack {
                Spacer()
                Button("Cancel") { stop(); onCancel() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    stop()
                    if let key { onSave(KeyBinding(key: key, modifiers: modifiers, text: text)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key == nil || text.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onDisappear { stop() }
    }

    private func startRecording() {
        stop()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if let d = KeyBinding.describe(e) {
                key = d.key
                modifiers = d.modifiers
                MainActor.assumeIsolated { stop() }
                return nil
            }
            return e
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
