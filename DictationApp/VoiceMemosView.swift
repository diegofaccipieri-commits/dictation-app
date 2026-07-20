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
        .frame(minWidth: 560, minHeight: 440)
        .tint(AppColors.voice)
        .background(AppColors.windowBG)
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
            .buttonStyle(.borderedProminent)
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
        HStack(spacing: 10) {
            Label("Voice Memos", systemImage: "headphones")
                .font(.headline)
            if store.isLoading { ProgressView().scaleEffect(0.5) }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                TextField("Buscar", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(width: 210)
            .background(RoundedRectangle(cornerRadius: 7).fill(AppColors.panel))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppColors.border, lineWidth: 1))
            Button {
                store.reload()
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Recarregar lista")
                .disabled(store.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(filtered) { memo in
                    MemoRow(memo: memo, selected: selection.contains(memo.id)) {
                        if selection.contains(memo.id) { selection.remove(memo.id) }
                        else { selection.insert(memo.id) }
                    }
                }
            }
            .padding(8)
        }
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
            HStack(spacing: 12) {
                Button(selection.count == filtered.count && !filtered.isEmpty ? "Limpar seleção" : "Selecionar todos") {
                    if selection.count == filtered.count { selection.removeAll() }
                    else { selection = Set(filtered.map { $0.id }) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Text("\(selection.count) selecionado\(selection.count == 1 ? "" : "s")")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle("Identificar falantes", isOn: $diarize)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Diarização por voz (mais lento; baixa um modelo na 1ª vez)")
                Button {
                    onTranscribe(selection, diarize)
                } label: {
                    Label("Transcrever selecionados", systemImage: "waveform.and.mic")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.voice)
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || store.isTranscribing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MemoRow: View {
    let memo: VoiceMemo
    let selected: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? AppColors.voice : Color.secondary.opacity(0.55), lineWidth: 1.6)
                        .background(Circle().fill(selected ? AppColors.voice : Color.clear))
                        .frame(width: 17, height: 17)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(memo.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(memo.dateText).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if memo.isTranscribed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .help("Já transcrito")
                }
                Text(memo.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? AppColors.voice.opacity(0.12)
                               : (hovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .onHover { hovered = $0 }
    }
}
