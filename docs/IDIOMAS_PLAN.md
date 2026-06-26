# Plano — Suporte a múltiplos idiomas (PT / EN / ES) no ditado e nas reuniões

> Problema relatado: ditar em inglês (ou espanhol) não é reconhecido; o app só pega português.
> Objetivo: ditar e transcrever em **PT, EN e ES**, com **auto-detecção** (trocar de idioma livremente)
> e a opção de **fixar** um idioma quando quiser.

Documento para o agente de codificação (Codex).

---

## 1. Diagnóstico (já confirmado no código)

- **Ditado ao vivo travado em PT** (`DictationApp/WhisperCpp.swift`, classe `WhisperCppServer`):
  - linha ~106: servidor sobe com `"--language", "pt"`;
  - linha ~185: cada request manda `appendFormField(name: "language", value: "pt", ...)`;
  - linha ~193: `prompt` é pt-específico ("Ditado em português do Brasil..."), o que **enviesa pra PT
    mesmo se o idioma fosse auto**.
- **Sem configuração de idioma**: não há `AppSettings.swift`; settings ficam em `UserDefaults` (via
  `@Published` no `DictationViewModel`) e nenhum deles é de idioma.
- Existe um caminho WhisperKit com `DecodingOptions(language: nil, detectLanguage: true)` (auto), mas o
  caminho **ativo** do ditado ao vivo usa o `WhisperCppServer` pt-travado (`TranscriptionManager.swift:144`).
- **Reuniões** já têm picker `auto/pt/en` (default `auto`) em `Reunioes/ReunioesView.swift` e
  `Reunioes/MeetingTranscript.swift` → falta **ES** e usar o setting compartilhado.

> Nota sobre "ao mesmo tempo": o Whisper detecta **um idioma por trecho de áudio**. Com `auto`, cada
> ditado/chunk é detectado isoladamente (fala em EN → EN; em PT → PT). Misturar dois idiomas **na mesma
> frase** faz o Whisper escolher o dominante. "Auto por utterance" é o comportamento desejado aqui.

---

## 2. Mudanças

### 2.1 Setting de idioma compartilhado
- **Não existe `AppSettings.swift`** neste projeto: os settings ficam em `UserDefaults` direto, expostos via
  `@Published` no `DictationViewModel` (ex.: `liveModel`, `batchModel`, `translationMode`). Seguir esse padrão.
- Criar enum `TranscriptionLanguage` (`auto | pt | en | es`) e uma propriedade
  `@Published var transcriptionLanguage` no `DictationViewModel`, backed pela chave UserDefaults
  `"transcriptionLanguage"`, **default `auto`**. (Trechos prontos na seção 7.)
- UI: um `Picker` de idioma no **popover (`ContentView`)**, junto dos pickers que já existem lá
  (`doubleTapKey`, `translationMode`), com Auto / Português / English / Español.

### 2.2 Ditado ao vivo (`WhisperCppServer` em `WhisperCpp.swift`)
- Tornar **idioma e prompt parametrizáveis** (vindos do setting), removendo o `"pt"` fixo:
  - O whisper.cpp server aceita `language` **por request** no `/inference` (o app já manda esse campo) →
    **trocar o valor fixo `"pt"` pelo setting** (`"auto"` quando auto). Isso evita reiniciar o servidor ao
    trocar de idioma. **Confirmar** que o server honra o `language` por request; se não honrar, reiniciar o
    servidor com o novo `--language` ao trocar o setting.
  - `--language` no start: pode ficar `auto` (já que o per-request sobrescreve) ou ser alinhado ao setting.
  - **Prompt dependente do idioma**: prompt pt atual só quando idioma = pt; para en/es usar prompt no
    idioma correspondente; para **auto, usar prompt neutro ou nenhum** (prompt pt enviesa a detecção).
- `WhisperCppServer.transcribe(samples:)`: receber `language` e `prompt`/`promptLanguage` como parâmetros
  (ou ler o setting), em vez de hardcode.

### 2.3 Pós-processamento pt-específico (`mergeFragmentedWords` / spell-check)
- Já usa `NLLanguageRecognizer` e trata pt/en; está **desligado por default** (`fragmentMergeEnabled`).
- Garantir que, com en/es, não aplique regras de PT. Para **es**, manter o merge desligado (não há
  dicionário pt aplicável) ou adaptar; é opcional, não bloqueia.

### 2.4 Reuniões
- Adicionar **ES** ao picker (`auto/pt/en/es`) em `ReunioesView.swift`.
- O default do idioma da reunião deve vir do **setting compartilhado** (não `"auto"` hardcoded), mantendo o
  override por reunião no picker.
- A futura transcrição **ao vivo** (plano `REUNIOES_AJUSTES_PLAN.md`, parte B) deve usar o mesmo setting ao
  chamar `WhisperCppServer.transcribe(samples:)`.

### 2.5 (Opcional, robustez) Auto em falas curtas
- `auto` pode errar o idioma em ditados **muito curtos**. Mitigações possíveis:
  - manter a opção de **fixar** o idioma (já contemplada no setting);
  - um atalho/menu rápido pra trocar idioma;
  - "modo bilíngue": tenta `auto`, mas se a confiança/duração for baixa, cai pro idioma fixo do usuário.

---

## 3. Arquivos tocados
- `DictationApp/TranscriptionLanguage.swift` (novo) — enum do idioma.
- `DictationApp/DictationViewModel.swift` — `@Published var transcriptionLanguage` (UserDefaults).
- `DictationApp/ContentView.swift` — `Picker` de idioma no popover.
- `DictationApp/WhisperCpp.swift` — `WhisperCppServer`: args do start, `language`/`prompt` por request.
- `DictationApp/TranscriptionManager.swift` — passar o idioma do setting para o `transcribe(samples:)`.
- `DictationApp/Reunioes/ReunioesView.swift` — adicionar ES; default do setting.
- `DictationApp/Reunioes/MeetingTranscript.swift` — (já recebe `language`; sem mudança estrutural).

## 4. Critério de aceite
- Idioma = **Auto**: ditar em PT → PT; em EN → EN; em ES → ES (cada ditado detectado isoladamente).
- Idioma **fixo** (PT/EN/ES): respeita a escolha em ditado e reuniões.
- Reuniões: ES disponível no picker; transcrição em qualquer um dos três.
- **PT (idioma primário) não regride** de forma perceptível.
- Ditado normal continua funcionando (uma instância, sem briga de porta 8178).

## 5. Higiene (de novo, porque já mordeu)
- Build limpo em pasta dedicada; assinar com cert `34A488...`; **uma instância só**; matar
  `whisper-server`/`whisper-cli` sobrando antes de testar.

## 6. Teste manual sugerido
1. Setting em Auto. Ditar uma frase em português → confere PT.
2. Ditar uma frase em inglês → confere EN (hoje falha; deve passar a pegar).
3. Ditar em espanhol → confere ES.
4. Fixar idioma em English e ditar PT → deve transcrever como EN (prova que o fixo manda).
5. Reunião com áudio EN/ES → transcreve correto (Auto e fixo).

---

## 7. Detalhamento — trechos prontos (para o Codex aplicar)

### 7.1 Novo arquivo `DictationApp/TranscriptionLanguage.swift`
```swift
import Foundation

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto, pt, en, es
    var id: String { rawValue }

    /// Valor enviado ao Whisper (servidor e CLI). "auto" faz o Whisper detectar o idioma.
    var whisperCode: String { rawValue }   // "auto" | "pt" | "en" | "es"

    var label: String {
        switch self {
        case .auto: return "Auto (detectar)"
        case .pt:   return "Português"
        case .en:   return "English"
        case .es:   return "Español"
        }
    }

    static var current: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "") ?? .auto
    }
}
```

### 7.2 `DictationViewModel.swift` — adicionar o setting (padrão dos já existentes)
```swift
@Published var transcriptionLanguage: TranscriptionLanguage =
    TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "") ?? .auto {
    didSet { UserDefaults.standard.set(transcriptionLanguage.rawValue, forKey: "transcriptionLanguage") }
}
```
> Se o ViewModel usa métodos `set...` em vez de `didSet`, seguir o mesmo estilo (ex.: `func setLanguage(_:)`).

### 7.3 `ContentView.swift` — Picker no popover (junto dos pickers existentes)
```swift
Picker("Idioma", selection: $viewModel.transcriptionLanguage) {
    ForEach(TranscriptionLanguage.allCases) { lang in
        Text(lang.label).tag(lang)
    }
}
.pickerStyle(.menu)
```
> `viewModel` aqui é o `DictationViewModel` já injetado no `ContentView`.

### 7.4 `WhisperCpp.swift` — `WhisperCppServer.start()` (linha ~106)
Trocar o idioma fixo por `auto` (o per-request sobrescreve):
```swift
// ANTES:
"--language", "pt", // bias live dictation toward Brazilian Portuguese
// DEPOIS:
"--language", "auto", // detecção automática; o idioma efetivo vai por request
```

### 7.5 `WhisperCpp.swift` — `WhisperCppServer.transcribe(...)` (linhas ~152, ~185, ~193)
Assinatura + campos do form passam a usar o idioma/prompt:
```swift
// Assinatura:
func transcribe(samples: [Float],
                language: String = TranscriptionLanguage.current.whisperCode,
                prompt: String? = nil) async -> String {
    ...
    // (no log de diagnostics, trocar "language": "pt" por "language": language)
    ...
    // Campo language (era value: "pt"):
    appendFormField(name: "language", value: language, boundary: boundary, to: &body)
    ...
    // Prompt dependente do idioma (era o prompt pt fixo):
    let promptText = prompt ?? Self.defaultPrompt(for: language)
    if !promptText.isEmpty {
        appendFormField(name: "prompt", value: promptText, boundary: boundary, to: &body)
    }
    ...
}

// Helper novo (static na WhisperCppServer):
static func defaultPrompt(for language: String) -> String {
    switch language {
    case "pt": return "Ditado em português do Brasil. Use palavras completas, ortografia correta e pontuação adequada. Preserve nomes próprios, marcas e termos técnicos em inglês quando forem ditos."
    case "en": return "Dictation in English. Use complete words, correct spelling and proper punctuation."
    case "es": return "Dictado en español. Usa palabras completas, ortografía correcta y puntuación adecuada."
    default:   return ""  // auto: SEM prompt, para não enviesar a detecção de idioma
    }
}
```
> Importante: em `auto`, **não enviar prompt** (o prompt pt era o que mais puxava a transcrição pra PT).

### 7.6 `TranscriptionManager.swift` — passar o idioma no caminho ativo (linha ~144)
```swift
// ANTES:
let text = await wcpp.transcribe(samples: samples)
// DEPOIS:
let text = await wcpp.transcribe(samples: samples, language: TranscriptionLanguage.current.whisperCode)
```
> (Opcional) No caminho WhisperKit (`DecodingOptions`, linhas ~77 e ~194): se o idioma for fixo, usar
> `language: code, detectLanguage: false`; se `auto`, manter `language: nil, detectLanguage: true`.
> Como o caminho ativo do ditado ao vivo é o servidor, isso é secundário.

### 7.7 Reuniões — `ReunioesView.swift` (picker) e `MeetingTranscript.swift`
```swift
// MeetingCard: default do setting, e adicionar ES no Picker
@State private var language = TranscriptionLanguage.current.whisperCode   // em vez de "auto" fixo
...
Picker("", selection: $language) {
    Text("Auto").tag("auto")
    Text("PT").tag("pt")
    Text("EN").tag("en")
    Text("ES").tag("es")
}
```
`MeetingTranscript.swift` já repassa `language` para `WhisperCppCLI.transcribeSegments(wav:language:)`,
e o `whisper-cli` aceita `-l auto|pt|en|es` — então **não precisa mudar a estrutura**, só passar ES quando escolhido.

### 7.8 Observação sobre o `whisper-server` honrar `language` por request
O app já manda `language` por request hoje (com valor "pt"), o que indica que o servidor respeita o
parâmetro. Se em testes o per-request **não** sobrescrever o `--language` do start, então:
reiniciar o servidor com o novo `--language` ao trocar o setting (parar/subir `WhisperCppServer`), ou
subir o servidor já com o idioma do setting. Confirmar empiricamente.
