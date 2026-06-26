# Plano de implementação — Módulo "Reuniões" no DictationApp

> Objetivo: adicionar ao DictationApp um gravador de reuniões que captura **microfone + áudio
> do sistema** em trilhas separadas, transcreve **localmente com Whisper** (reusando a engine
> que já existe no app) e mostra **waveforms + transcrição "Você/Outros" com timestamps**.
> Futuro: diarização real dos "Outros", notas com IA e transcrição ao vivo.

Este documento é a especificação para o agente de codificação (Codex). Já existe um **rascunho
funcional** na branch `feature/reunioes` (commit `cb09a2a`); ele **compila e roda**, mas tem **um
bug de captura** (ver seção 5) que precisa ser resolvido. O Codex pode partir desse rascunho e
corrigir, ou reimplementar seguindo a spec.

---

## 1. Contexto e restrições

- App: DictationApp (macOS, SwiftUI + AppKit, menu bar / `NSApplicationDelegateAdaptor`).
  Entry point: `DictationApp/DictationApp.swift` → `AppDelegate.swift` (policy `.accessory`).
- Gerenciado por **XcodeGen** (`project.yml` é a fonte de verdade; o `.xcodeproj` é gerado).
- **Reusar o que já existe** (não reimplementar):
  - `WhisperCppCLI.transcribeSegments(wav:language:onProgress:)` em `DictationApp/WhisperCpp.swift`
    (roda o binário `whisper-cli` empacotado, idioma `auto`, devolve segmentos com timestamps).
  - `AudioDecoder.decodeToWav(_:)` em `DictationApp/AudioDecoder.swift` (qualquer áudio → WAV 16 kHz mono).
  - `DiarizationService` (FluidAudio) em `DictationApp/DiarizationService.swift` (para a fase de diarização).
  - Binário `whisper-cli` + modelo `ggml-large-v3-turbo-q5_0.bin` (já presentes/baixados).
- **macOS alvo**: deployment target do app é **14.0**. A captura de reunião usa ScreenCaptureKit
  com microfone, que exige **macOS 15+** → todo o código de captura é `@available(macOS 15, *)`
  e o ponto de entrada (menu) faz `guard #available(macOS 15, *)`.
- **Assinatura local estável** (para o macOS não pedir permissões a cada build): certificado
  self-signed **"DictationApp Dev"**, SHA-1 `34A488E1BA65A57C8D37EC51E342923ACA9D891C`.
  Assinar sempre com ele mantém o requisito designado fixo (`identifier + certificate leaf`),
  então as permissões TCC (Microfone / Gravação de Tela) persistem entre builds.

---

## 2. Arquitetura

```
[Gravar]
  ├─ Microfone  ──► trilha "Você"   (arquivo _mic.m4a)
  └─ Áudio do sistema ──► trilha "Outros" (arquivo _system.m4a)
[Parar]
  └─ por trilha: decodifica → whisper-cli (idioma auto PT/EN) → segmentos c/ timestamp
       ├─ mic    → rótulo "Você"
       └─ sistema→ rótulo "Outros"  (futuro: diarizar em Falante 1/2/3 com FluidAudio)
  └─ funde por tempo → agrupa em parágrafos → mostra balões + persiste JSON
Futuro: notas com IA a partir da transcrição; transcrição ao vivo durante a gravação.
```

A separação por trilha já dá um "quem falou" básico (eu vs. os outros) sem diarização.

---

## 3. Arquivos do módulo (pasta `DictationApp/Reunioes/`)

Todos já existem na branch `feature/reunioes`. Responsabilidades:

| Arquivo | Papel |
|---|---|
| `MeetingPaths.swift` | Pastas em `~/Library/Application Support/DictationApp/Meetings/Audio/`; helpers de timestamp. |
| `MeetingPermissions.swift` | Snapshot/solicitação de Microfone (`AVCaptureDevice`) e Gravação de Tela (`CGPreflight/RequestScreenCaptureAccess`). |
| `MeetingCaptureEngine.swift` | **(contém o bug — ver seção 5)** Captura mic + sistema e grava 2 `.m4a`. |
| `MeetingRecorder.swift` | `@MainActor ObservableObject`: ciclo gravar/parar, timer, permissões, lista de reuniões. |
| `MeetingsStore.swift` | Lista reuniões pareando `meeting_<stamp>_mic.m4a` / `_system.m4a`. |
| `MeetingWaveform.swift` | `MeetingWaveformLoader` (picos), `MeetingWaveformView` (Canvas), `MeetingPlayer` (playback + playhead). |
| `MeetingTranscript.swift` | `MeetingSegment` (Codable), `MeetingTranscriptStore` (JSON sidecar), `MeetingGrouping` (parágrafos), `MeetingTranscriber` (chama `WhisperCppCLI` por trilha, rotula Você/Outros). |
| `ReunioesView.swift` | Janela SwiftUI: gravar/parar, permissões, lista com waveforms (Você/Outros) e transcrição (botão Transcrever + idioma Auto/PT/EN + balões). |

---

## 4. Integração (wiring)

### 4.1 `AppDelegate.swift`
- Propriedade: `private var meetingsWindow: NSWindow?`
- Item de menu no `showContextMenu()` (logo após "Transcrever do Voice Memos…"):
  `NSMenuItem(title: "Gravar Reunião…", action: #selector(showReunioes), keyEquivalent: "")` (target self).
- Método `@objc func showReunioes()`:
  - `guard #available(macOS 15, *) else { notify("requer macOS 15"); return }`
  - cria um `NSWindow` (titled/closable/resizable, ~640×540), `contentViewController = NSHostingController(rootView: ReunioesView())`,
    `isReleasedWhenClosed = false`, guarda em `meetingsWindow`, `makeKeyAndOrderFront`.
  - (mesmo padrão de `showVoiceMemos()`).

### 4.2 `project.yml`
- `targets.DictationApp.dependencies`: **adicionar `- package: FluidAudio`**.
  (O `FluidAudio` já está em `packages:`, mas estava faltando em `dependencies:`; sem isso o
  `.xcodeproj` gerado quebra com erros `FastClusterWrapper`/`MachTaskSelfWrapper`. O `.xcodeproj`
  commitado tinha o FluidAudio adicionado **à mão** — adicionar em `dependencies` torna a
  regeneração via xcodegen reproduzível.)
- `info.properties`: **adicionar** `NSScreenCaptureUsageDescription` (texto explicando captura do
  áudio do sistema nas reuniões).
- `info.properties`: **fixar a versão** (`CFBundleShortVersionString` / `CFBundleVersion`), senão o
  xcodegen reseta o Info.plist para `1.0` ao regenerar. Sugestão: **1.25.0 / 1250** (feature nova).
  > Atenção: o `release.sh` seta a versão via PlistBuddy. Alinhar a estratégia de versão ao mesclar
  > na `main` (decidir se a versão fica no `project.yml` ou só no fluxo do release).

---

## 5. BUG A RESOLVER (crítico): "stream failed to start audio"

**Sintoma:** ao clicar Gravar, `SCStream.startCapture()` lança erro e a UI mostra
"stream failed to start audio". As permissões aparecem concedidas (o botão Gravar exige
`CGPreflightScreenCaptureAccess()==true` e mic autorizado).

**Config atual (em `MeetingCaptureEngine.swift`)** captura **sistema (.audio) + microfone (.microphone)
no MESMO `SCStream`** (via `config.captureMicrophone = true` + `addStreamOutput(... type: .microphone ...)`),
sem adicionar output `.screen`, com vídeo 2×2.

**Passos para o Codex:**

1. **Capturar o erro exato primeiro** (não chutar): no `catch` do `start()`, logar o `NSError`
   completo (`domain`, `code`, `userInfo`) — ex.: `(error as NSError)` — e/ou usar
   `log stream --predicate 'subsystem == "com.diego.dictationapp"'` enquanto reproduz. Anotar o
   `SCStreamError` code.

2. **Teste de isolamento:** rodar a captura **só com o áudio do sistema** (sem
   `captureMicrophone`, sem o output `.microphone`). Se iniciar normalmente, o problema é
   especificamente o microfone dentro do `SCStream`.

3. **Correção recomendada (mais robusta): separar o microfone do SCStream.**
   - Áudio do sistema: continuar via `SCStream` (output `.audio`) → grava `_system.m4a`.
   - Microfone: capturar **em paralelo com `AVAudioEngine`** (tap no `inputNode`) → grava
     `_mic.m4a` (ex.: `AVAudioFile` ou `AVAssetWriter`).
   - Alinhar as duas trilhas pelo relógio de parede (marcar `Date()` no início de cada uma).
   - Vantagens: evita a fragilidade de mic+sistema no mesmo stream; o mic passa a funcionar em
     macOS 14 também (só o áudio do sistema exige 13+; pode-se baixar o `@available` para 14).
   - Tratar troca de dispositivo (`AVAudioEngineConfigurationChange`) e parar/finalizar limpo.

4. **Alternativas se quiser manter o stream único** (testar nesta ordem só se (3) não for desejado):
   - Adicionar um output `.screen` (consumir e descartar os frames) — alguns setups exigem o
     pipeline de vídeo ativo.
   - Definir `config.microphoneCaptureDeviceID` explicitamente.
   - Aumentar o vídeo de 2×2 para algo válido (ex.: 16×16).

5. **Permissão concedida com app aberto:** mesmo com `CGPreflight==true`, a captura pode falhar até
   reabrir o app. Tratar com mensagem clara ("conceda a permissão e reabra o app") e reverificar
   permissões ao voltar o foco da janela.

**Critério de aceite do bug:** clicar Gravar inicia sem erro; ao parar, existem dois `.m4a` (mic e
sistema) com áudio correto e separado (mic = só sua voz; sistema = só o áudio do app/vídeo).

---

## 6. Build, assinatura e instalação

> Lições desta sessão embutidas aqui — seguir à risca evita os problemas que tivemos.

1. **Regenerar o projeto:** `cd ~/dictation-app && xcodegen generate`.

2. **Build LIMPO em pasta dedicada** (NÃO usar o DerivedData compartilhado, que guarda artefatos
   velhos e já causou confusão de versão/binário):
   ```sh
   xcodebuild -scheme DictationApp -configuration Release \
     -derivedDataPath build-reunioes build \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
   ```
   - Preferir **Release** para instalar: gera um binário único.
   - Em **Debug**, o Xcode 26 usa um `DictationApp.debug.dylib` e o executável principal é só um
     stub — ao verificar com `strings`, conferir o **`.debug.dylib`**, não o stub. (Isso gerou
     falso "código não está no binário" duas vezes.)

3. **Assinar com o cert estável** (cobre `--deep`: frameworks, `whisper-cli`/dylibs em Resources,
   debug.dylib):
   ```sh
   APP=build-reunioes/Build/Products/Release/DictationApp.app
   codesign -f -s 34A488E1BA65A57C8D37EC51E342923ACA9D891C --deep "$APP"
   codesign --verify --deep --strict "$APP"
   codesign -d -r- "$APP" | grep designated   # deve mostrar identifier + certificate leaf 34a488...
   ```

4. **Verificar ANTES de abrir** (não repetir o erro de abrir build errado):
   - versão: `PlistBuddy -c "Print :CFBundleShortVersionString"` == esperado (ex. 1.25.0).
   - feature presente: `strings -a "$APP/Contents/MacOS/DictationApp"` (Release) por
     `MeetingRecorder` / `Gravar Reuni` (em Debug, usar o `.debug.dylib`).

5. **Instalar** (como o `scripts/release.sh` já faz): substituir `/Applications/DictationApp.app`
   pelo build assinado; ou rodar `scripts/release.sh <versão>` para release tagueado no GitHub.

6. **Higiene de processos (importante):** o app sobe um `whisper-server` na **porta 8178** ao
   transcrever. **Não rodar várias instâncias** do app ao mesmo tempo (brigam pela porta 8178 e
   pelo microfone → derruba o ditado). Ao testar builds de dev, **matar sobras** antes:
   ```sh
   pkill -9 -x DictationApp; pkill -9 -f whisper-server; pkill -9 -f whisper-cli
   ```
   e abrir **apenas uma** instância.

---

## 7. Checklist de verificação (feature de captura)

- [ ] `xcodegen generate` sem erro; build Release passa.
- [ ] App assinado com cert estável; requisito designado = `identifier + leaf 34a488...`.
- [ ] Menu (botão direito no ícone) tem "Gravar Reunião…"; abre a janela Reuniões.
- [ ] Permissões: Microfone e Gravação de Tela; após conceder Gravação de Tela, reabrir o app.
- [ ] Gravar → falar + tocar um vídeo → Parar gera dois `.m4a` (mic e sistema) separados e corretos.
- [ ] Waveforms aparecem nas duas trilhas; playback com playhead.
- [ ] Transcrever (Auto) roda o whisper-cli na GPU e mostra balões "Você/Outros" com timestamps.
- [ ] O **ditado normal continua funcionando** com a feature instalada (sem regressão).

---

## 8. Roadmap (depois que a captura funcionar)

1. **Diarização dos "Outros"** com `DiarizationService` (FluidAudio): decodificar a trilha do
   sistema em samples 16 kHz, `diarize(samples:)` → `[SpeakerTurn]`, atribuir Falante 1/2/3 por
   sobreposição de tempo aos segmentos do whisper (padrão já usado no `BatchTranscriber`).
2. **Notas com IA**: a partir da transcrição diarizada, gerar resumo, decisões, itens de ação,
   tópicos (Claude API opt-in, ou modelo local). Chunking para reuniões longas.
3. **Transcrição ao vivo** durante a gravação (streaming), reconciliando com o passo final.
4. **Empacotamento dos modelos/binários** para distribuição (download no 1º uso; hoje reusa o
   modelo já baixado em `~/Documents/huggingface/models/whisper.cpp/`).

---

## 9. Estado atual (ponto de partida)

- Branch: `feature/reunioes` (commit `cb09a2a`) — 8 arquivos em `DictationApp/Reunioes/` + wiring
  no `AppDelegate.swift` + `project.yml` (FluidAudio em deps, permissão de tela, versão 1.25.0).
- `main` está intacta em **1.24.6** (release publicado). Não mexer na `main` até a feature estar pronta.
- Pendência única para um MVP utilizável: **resolver o bug da seção 5** (captura). O resto (UI,
  transcrição Whisper, waveforms, persistência) já está implementado e compilando.
