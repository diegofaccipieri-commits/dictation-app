import SwiftUI
import AppKit

struct VoiceMemosView: View {
    @ObservedObject var store: VoiceMemosStore
    let onTranscribe: (Set<String>, Bool) -> Void

    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var diarize = false

    private var filtered: [VoiceMemo] {
        guard !search.isEmpty else { return store.memos }
        return store.memos.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.accessDenied {
                accessDeniedView
            } else if store.memos.isEmpty && !store.isLoading {
                emptyView
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 420)
        .onAppear { if store.memos.isEmpty { store.reload() } }
    }

    private var accessDeniedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundColor(.secondary)
            Text("Sem acesso aos Voice Memos").font(.headline)
            Text("O macOS exige Acesso Total ao Disco para o app ler suas gravações. Conceda a permissão, reinicie o app e recarregue.")
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Abrir Acesso Total ao Disco") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform.slash").font(.system(size: 36)).foregroundColor(.secondary)
            Text("Nenhuma gravação encontrada").font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
            Text("Voice Memos").font(.headline)
            if store.isLoading { ProgressView().scaleEffect(0.5) }
            Spacer()
            TextField("Buscar…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button {
                store.reload()
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Recarregar lista")
                .disabled(store.isLoading)
        }
        .padding(10)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filtered) { memo in
                HStack(spacing: 10) {
                    Image(systemName: memo.isTranscribed ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(memo.isTranscribed ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(memo.title).lineLimit(1)
                        Text(memo.dateText).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(memo.durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .tag(memo.id)
                .contentShape(Rectangle())
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let status = store.status {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5)
                    Text(status).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
            }
            HStack {
                Button(selection.count == filtered.count && !filtered.isEmpty ? "Limpar seleção" : "Selecionar todos") {
                    if selection.count == filtered.count { selection.removeAll() }
                    else { selection = Set(filtered.map { $0.id }) }
                }
                .controlSize(.small)
                Text("\(selection.count) selecionado(s)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle("Identificar falantes", isOn: $diarize)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Diarização por voz (mais lento; baixa um modelo na 1ª vez)")
                Button {
                    onTranscribe(selection, diarize)
                } label: {
                    Label("Transcrever selecionados", systemImage: "doc.text.magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || store.isTranscribing)
            }
        }
        .padding(10)
    }
}
