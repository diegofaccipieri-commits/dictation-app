import AppKit
import SwiftUI

@MainActor
final class TranslationWorkspaceViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var outputText = ""
    @Published var selectedMode: TranslationMode
    @Published var isTranslating = false
    @Published var errorMessage: String?

    private let translator: ClaudeTranslator

    init(translator: ClaudeTranslator) {
        self.translator = translator
        let saved = TranslationMode(
            rawValue: UserDefaults.standard.string(forKey: "manualTranslationMode") ?? ""
        )
        selectedMode = saved == nil || saved == .off ? .ptEnEveryday : saved!
    }

    var canTranslate: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTranslating
    }

    func setMode(_ mode: TranslationMode) {
        selectedMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "manualTranslationMode")
        warmUp()
    }

    func warmUp() {
        let mode = selectedMode
        Task { await translator.warmUp(mode: mode) }
    }

    func translate() {
        let source = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !isTranslating else { return }

        isTranslating = true
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            let mode = selectedMode
            var translated: String?
            if #available(macOS 15.0, *), TranslationMode.directModes.contains(mode) {
                translated = await AppleTranslator.shared.translate(source, mode: mode)
            }
            if translated == nil {
                translated = await translator.translate(source, mode: mode)
            }
            isTranslating = false
            if let translated {
                outputText = translated
            } else {
                errorMessage = "Não foi possível concluir a tradução. Verifique o Claude e tente novamente."
            }
        }
    }

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
    }

    func clear() {
        inputText = ""
        outputText = ""
        errorMessage = nil
    }
}

struct TranslationWorkspaceView: View {
    @ObservedObject var viewModel: TranslationWorkspaceViewModel

    private var availableModes: [TranslationMode] {
        TranslationMode.profileModes + TranslationMode.directModes
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HSplitView {
                textPanel(
                    title: "TEXTO PARA TRADUZIR",
                    placeholder: "Digite ou cole aqui o texto que você quer traduzir…",
                    text: $viewModel.inputText,
                    characterCount: viewModel.inputText.count
                )

                textPanel(
                    title: "TRADUÇÃO FINALIZADA",
                    placeholder: viewModel.isTranslating ? "Traduzindo…" : "A tradução aparecerá aqui…",
                    text: $viewModel.outputText,
                    characterCount: viewModel.outputText.count
                )
            }
            .padding(16)

            footer
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(AppColors.windowBG)
        .tint(AppColors.voice)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tradução de texto")
                    .font(.system(size: 20, weight: .bold))
                Text("Escolha o modo, escreva o texto e receba a versão final ao lado.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Picker("Modo", selection: Binding(
                get: { viewModel.selectedMode },
                set: { viewModel.setMode($0) }
            )) {
                Section("MODOS") {
                    ForEach(TranslationMode.profileModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Section("DIREÇÕES DIRETAS") {
                    ForEach(TranslationMode.directModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(width: 235)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(AppColors.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.borderSoft).frame(height: 1)
        }
    }

    private func textPanel(
        title: String,
        placeholder: String,
        text: Binding<String>,
        characterCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(characterCount) caracteres")
                    .font(.caption2)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }

            ZStack(alignment: .topLeading) {
                AlignedTextEditor(text: text)

                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundColor(Color(NSColor.placeholderTextColor))
                        .padding(.horizontal, AlignedTextEditor.textInset.width)
                        .padding(.vertical, AlignedTextEditor.textInset.height)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.borderSoft, lineWidth: 1))
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .padding(4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if viewModel.isTranslating {
                ProgressView().controlSize(.small)
                Text("Traduzindo com \(viewModel.selectedMode.displayName)…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("⌘↩ traduz")
                    .font(.caption)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }

            Spacer()

            Button("Limpar", action: viewModel.clear)
                .disabled(viewModel.inputText.isEmpty && viewModel.outputText.isEmpty)

            Button(action: viewModel.copyOutput) {
                Label("Copiar tradução", systemImage: "doc.on.doc")
            }
            .disabled(viewModel.outputText.isEmpty)

            Button(action: viewModel.translate) {
                if viewModel.isTranslating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Traduzir", systemImage: "arrow.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!viewModel.canTranslate)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(AppColors.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(AppColors.borderSoft).frame(height: 1)
        }
    }
}

private struct AlignedTextEditor: NSViewRepresentable {
    static let textInset = NSSize(width: 10, height: 11)

    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        // Edits typed in the view already match the binding; only push external changes.
        if text != context.coordinator.lastText {
            context.coordinator.lastText = text
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, text.utf16.count),
                length: 0
            ))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var lastText = ""

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let current = textView.string
            lastText = current
            text = current
        }
    }
}
