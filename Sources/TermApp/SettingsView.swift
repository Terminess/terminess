import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @State private var editing: Theme?
    @State private var editingForDark = true
    private let fonts = Settings.monospacedFonts()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: $settings.appearance) {
                    Text("Follow System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
                ThemePicker(title: "Light theme", selection: $settings.lightTheme, themes: settings.allThemes) {
                    edit(settings.theme(named: settings.lightTheme, fallbackDark: false), forDark: false)
                }
                ThemePicker(title: "Dark theme", selection: $settings.darkTheme, themes: settings.allThemes) {
                    edit(settings.theme(named: settings.darkTheme, fallbackDark: true), forDark: true)
                }
                HStack {
                    Button("Import iTerm2 Colours…", action: importITerm)
                    Spacer()
                    if !settings.customThemes.isEmpty {
                        Menu("Delete Custom Theme") {
                            ForEach(settings.customThemes) { t in
                                Button(t.name) { settings.deleteCustom(t.name) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }

            Section("Text") {
                Picker("Font", selection: $settings.fontName) {
                    Text("SF Mono (system)").tag("")
                    Divider()
                    ForEach(fonts, id: \.1) { family, ps in
                        Text(family).tag(ps)
                    }
                }
                Stepper(value: $settings.fontSize, in: 8...36, step: 1) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(settings.fontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack {
                    Text("Line spacing")
                    Slider(value: $settings.lineSpacing, in: 1.0...1.6, step: 0.05)
                    Text(String(format: "%.2f", settings.lineSpacing)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Toggle("Thin strokes", isOn: $settings.thinStrokes)
                Text("Draws text without macOS font smoothing, which otherwise makes it look heavier. iTerm2 does this by default on Retina screens.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cursor") {
                Picker("Shape", selection: $settings.cursorShape) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $settings.cursorBlink)
            }

            Section("Keyboard") {
                Picker("Option key", selection: $settings.optionKey) {
                    Text("Left Option is Meta").tag("left")
                    Text("Both Option keys are Meta").tag("both")
                    Text("Normal (type special characters)").tag("none")
                }
                Text("Meta sends Escape before the key, which shells and editors use for word movement and shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Windows, Tabs and Scrollback") {
                HStack {
                    Text("New windows open in")
                    Spacer()
                    Text(settings.startFolder.isEmpty ? "Home folder" : abbreviate(settings.startFolder))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                    if !settings.startFolder.isEmpty {
                        Button("Reset") { settings.startFolder = "" }
                    }
                }
                Toggle("New tabs open in the current tab's folder", isOn: $settings.newTabsInCurrentFolder)
                Picker("Scrollback", selection: $settings.scrollback) {
                    Text("1,000 lines").tag(1_000)
                    Text("10,000 lines").tag(10_000)
                    Text("50,000 lines").tag(50_000)
                    Text("100,000 lines").tag(100_000)
                }
                Text("Scrollback applies to new tabs.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $editing) { theme in
            ThemeEditor(theme: theme) { saved in
                settings.saveCustom(saved)
                if editingForDark { settings.darkTheme = saved.name } else { settings.lightTheme = saved.name }
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private func edit(_ theme: Theme, forDark: Bool) {
        var t = theme
        if t.builtIn { t.name = "\(t.name) (Custom)"; t.builtIn = false }
        editingForDark = forDark
        editing = t
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
