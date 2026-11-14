import HealthDataRelayKit
import SwiftUI
import UniformTypeIdentifiers

/// The templates pipelines can write with: the app's, and the user's own.
struct TemplatesView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var importError: String?
    @State private var newEditor: NewTemplate?
    @State private var unlocking = false

    /// Writing your own templates is part of Full; the built-ins stay free.
    private func ifUnlocked(_ action: () -> Void) {
        if model.store.access.allowsCustomTemplates { action() } else { unlocking = true }
    }

    struct NewTemplate: Identifiable, Hashable {
        let id = UUID()
        let source: String
    }

    static let starter = """
    ---
    name: My template
    format: csv
    data: [metrics]
    ---
    date,steps,source
    {% for p in metrics.step_count.data %}{{ p.date | date: '%Y-%m-%d' }},{{ p.qty }},{{ p.source }}
    {% endfor %}
    """

    var body: some View {
        NavigationStack {
            List {
                Section("Built in") {
                    ForEach(model.library.entries().filter { if case .builtIn = $0.ref { true } else { false } }) { entry in
                        NavigationLink {
                            BuiltInTemplateView(entry: entry) { source in ifUnlocked { newEditor = NewTemplate(source: source) } }
                        } label: {
                            TemplateRow(entry: entry)
                        }
                    }
                }
                Section {
                    ForEach(model.customTemplates) { custom in
                        NavigationLink {
                            TemplateEditor(id: custom.id, source: custom.source)
                        } label: {
                            if let name = custom.name, let format = custom.format {
                                TemplateRow(entry: .init(ref: .custom(custom.id), name: name, format: format))
                            } else {
                                Text("Unreadable template").foregroundStyle(.red)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { model.removeTemplate(model.customTemplates[i].id) }
                    }
                    Button {
                        ifUnlocked { newEditor = NewTemplate(source: Self.starter) }
                    } label: {
                        Label("New template", systemImage: "plus")
                    }
                    .accessibilityIdentifier("new-template")
                    Button {
                        ifUnlocked { importing = true }
                    } label: {
                        Label("Import a file", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("import-template")
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("import-error")
                    }
                } header: {
                    Text("Yours")
                } footer: {
                    Text("A template is a text file, a header and a body in Liquid. It can't reach the network or other files.")
                }
            }
            .navigationTitle("Templates")
            .onAppear { model.reloadTemplates() }
            .sheet(isPresented: $unlocking) { UnlockView() }
            .navigationDestination(item: $newEditor) { new in
                TemplateEditor(id: nil, source: new.source)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "liquid") ?? .plainText, .text]) { result in
                switch result {
                case .success(let url):
                    do {
                        _ = try model.library.importFile(url)
                        importError = nil
                        model.reloadTemplates()
                    } catch {
                        importError = String(describing: error)
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
        }
    }
}

private struct TemplateRow: View {
    let entry: TemplateLibrary.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
            Text(entry.format.title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A built-in template: read it, try it, or copy it to change it.
private struct BuiltInTemplateView: View {
    @Environment(AppModel.self) private var model
    let entry: TemplateLibrary.Entry
    let copy: (String) -> Void

    private var source: String { model.library.source(entry.ref) ?? "" }

    var body: some View {
        List {
            if let description = entry.description {
                Section { Text(description) }
            }
            Section {
                Button("Make a copy to edit") { copy(source) }
                    .accessibilityIdentifier("copy-template")
                ShareLink("Share this file", item: source, preview: SharePreview(TemplateLibrary.exportName(entry.name)))
            }
            Section("Source") {
                Text(source)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Edit a template's text and see what it writes, on sample data or your own.
struct TemplateEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil until it's first saved.
    @State var id: UUID?
    @State var source: String
    @State private var preview = TemplatePreview.Result()
    @State private var showing = 0
    @State private var realData = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $showing) {
                Text("Edit").tag(0)
                Text("Preview").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("template-view")

            if let error = preview.error {
                Label(where_ + error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("template-error")
            }

            if showing == 0 {
                CodeEditor(text: $source)
                    .accessibilityIdentifier("template-source")
            } else {
                previewBody
            }
        }
        .navigationTitle(preview.parts.isEmpty && preview.error != nil ? "Template" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled((try? ParsedTemplate(source: source)) == nil)
                    .accessibilityIdentifier("save-template")
            }
            ToolbarItem(placement: .secondaryAction) {
                ShareLink("Share this file", item: source, preview: SharePreview(TemplateLibrary.exportName(name)))
            }
        }
        // Re-renders when typing pauses.
        .task(id: "\(source)|\(realData)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = await TemplatePreview.render(source: source, store: realData ? model.queries : nil)
            if !Task.isCancelled { preview = result }
        }
        .alert("Couldn't save", isPresented: Binding { saveError != nil } set: { if !$0 { saveError = nil } }) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var where_: String {
        guard let line = preview.line else { return "" }
        if let column = preview.column { return "Line \(line), column \(column): " }
        return "Line \(line): "
    }

    private var name: String {
        (try? ParsedTemplate(source: source))?.header.name ?? "Template"
    }

    @ViewBuilder private var previewBody: some View {
        List {
            Section {
                Toggle("Use my Health data", isOn: $realData)
                    .accessibilityIdentifier("preview-real-data")
            } footer: {
                Text(realData ? "The last three days, grouped by day. Nothing leaves your iPhone." : "Made-up sample data.")
            }
            ForEach(Array(preview.parts.enumerated()), id: \.offset) { _, part in
                Section {
                    Text(part.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("preview-output")
                } header: {
                    Text(part.filename).textCase(nil)
                } footer: {
                    if part.isTruncated { Text("Only the start is shown.") }
                }
            }
        }
    }

    private func save() {
        do {
            id = try model.library.save(source, id: id ?? UUID())
            model.reloadTemplates()
            dismiss()
        } catch {
            saveError = String(describing: error)
        }
    }
}

/// A plain text view for code. SwiftUI's TextEditor can't turn off smart
/// punctuation, which would turn `---` and `'` into characters Liquid can't read.
private struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        #if !os(visionOS)
        view.keyboardDismissMode = .interactive
        #endif
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
        }
    }
}
