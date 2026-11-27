# Calendário na barra de menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Calendário configurável (cidades, relógios, formato, domingo) com menu no clique direito, distribuído dentro do DictationApp.

**Architecture:** `RelogioDuplo/` é um Swift Package com `RelogioDuploCore` (lógica pura, testada) e `RelogioDuplo` (AppKit `NSStatusItem` + popover e janela em SwiftUI). O DictationApp ganha `CalendarCompanion`, que instala e inicia o app embutido. `release.sh` embute e assina.

**Tech Stack:** Swift 6 (calendário), Swift 5.9 (DictationApp), AppKit, SwiftUI, ServiceManagement, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-27-calendario-na-barra-design.md`

## Global Constraints

- Calendário: macOS 14+, identificador `com.diegofaccipieri.RelogioDuplo`, `LSUIElement`.
- De 1 a 4 relógios. Sigla com até 4 caracteres, maiúsculas.
- Chaves: `settings` (JSON em texto) e `disabledByHost` no domínio do calendário; `calendarCompanionEnabled` no DictationApp.
- Textos da UI em português.
- Sem push, sem release, sem mexer em `whisper.cpp`.
- Nunca usar travessão. Commits terminam com `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Ponto de partida: o código já copiado para `RelogioDuplo/` (20 testes passando).

## Review Focus

1. Ajustes gravados por versão futura ou corrompidos: o app abre com o padrão, sem travar.
2. Lista de relógios vazia ou com mais de 4 no JSON: normaliza para 1 a 4.
3. Sigla colada com espaços, acentos ou 20 caracteres: vira no máximo 4, maiúsculas.
4. DictationApp sem app embutido ou sem permissão de escrita em `/Applications`: registra no log e segue.
5. Calendário aberto durante a troca do binário: fecha antes de substituir e reabre depois.

---

### Task 1: Ajustes (Core)

**Files:** Create `RelogioDuplo/Sources/RelogioDuploCore/Settings.swift`; Test `RelogioDuplo/Tests/RelogioDuploCoreTests/SettingsTests.swift`

**Interfaces (Produces):**

```swift
public struct Clock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var zoneID: String
    public var label: String
    public init(id: UUID = UUID(), zoneID: String, label: String)
    public static func cleanLabel(_ raw: String) -> String   // sem espaços e acentos, maiúsculas, até 4
}
public struct Settings: Codable, Equatable, Sendable {
    public static let maxClocks = 4
    public var clocks: [Clock]
    public var uses24Hour: Bool
    public var redSunday: Bool
    public static func defaults(systemZone: TimeZone) -> Settings
    public func normalized(systemZone: TimeZone) -> Settings   // 1 a 4 relógios, siglas limpas
    public static func decode(_ json: String?, systemZone: TimeZone) -> Settings  // ilegível: padrão
    public func encoded() -> String
}
```

Testes: padrão tem 1 relógio do fuso dado, 24h, domingo ligado; ida e volta do JSON; `nil`, texto inválido e JSON de outro formato caem no padrão; campos ausentes usam o padrão do campo; 0 relógios vira 1; 6 viram 4; `cleanLabel(" são paulo xx ")` = `SAOP`; `cleanLabel("to")` = `TO`.

- [ ] Teste falhando, implementação, suíte verde, commit `feat(calendario): ajustes do calendario`.

### Task 2: Catálogo de cidades (Core)

**Files:** Create `.../RelogioDuploCore/CityCatalog.swift`; Test `.../CityCatalogTests.swift`

**Interfaces (Produces):**

```swift
public struct City: Equatable, Sendable, Identifiable {
    public let zoneID: String
    public let name: String      // cidade exemplar do fuso, localizada
    public let region: String    // primeiro trecho do identificador
    public var id: String { zoneID }
}
public enum CityCatalog {
    public static func all(locale: Locale) -> [City]            // ordenado por nome
    public static func name(for zoneID: String, locale: Locale) -> String
    public static func search(_ query: String, in cities: [City]) -> [City]
    public static func suggestedLabel(for name: String) -> String
}
```

Testes: catálogo contém `America/Toronto` e `America/Sao_Paulo`, sem fusos `Etc/` ou `GMT`; nome de `America/Sao_Paulo` em `pt_BR` é `São Paulo`; busca `sao pa` acha São Paulo; busca vazia devolve tudo; busca por `toronto` minúsculo; siglas `São Paulo`=`SP`, `New York`=`NY`, `Toronto`=`TO`, `Rio de Janeiro`=`RDJ`, texto vazio=``; fuso desconhecido devolve o último trecho do identificador.

- [ ] Teste falhando, implementação, suíte verde, commit `feat(calendario): catalogo de cidades`.

### Task 3: Texto da barra com N relógios e 12h (Core)

**Files:** Modify `.../RelogioDuploCore/MenuBarText.swift`; Modify `.../MenuBarTextTests.swift`

**Interfaces (Produces, substitui `make(now:systemCalendar:)`):**

```swift
public enum MenuBarText {
    public enum Piece: Equatable, Sendable { case main(String), small(String) }
    public static func pieces(now: Date, systemCalendar: Calendar, settings: Settings) -> [Piece]
    public static func plain(now: Date, systemCalendar: Calendar, settings: Settings) -> String
}
```

Peças para TO e SP em 24h: `main("27 - 20:41")`, `small(" TO")`, `main(" - 22:41")`, `small(" SP")`. Em 12h: `main("27 - 8:41")`, `small(" PM TO")`, `main(" - 10:41")`, `small(" PM SP")`.

Testes: os 8 casos atuais continuam valendo via `plain` com ajustes TO e SP em 24h; 12h às 0:05 = `12:05 AM`, às 12:00 = `12:00 PM`, às 20:41 = `8:41 PM`; 1 relógio; 4 relógios; sigla vazia em 24h e em 12h (`small(" PM")`); fuso inválido `--:--`; peças exatas do exemplo; dia segue o sistema em Tóquio.

- [ ] Teste falhando, implementação, suíte verde, commit `feat(calendario): texto da barra com varios relogios e 12h`.

### Task 4: App em AppKit com menu, popover e janela de cidades

**Files (em `RelogioDuplo/Sources/RelogioDuplo/`):**
- Delete: `RelogioDuploApp.swift`, `ClockModel.swift`
- Create: `main.swift` (NSApplication + delegate), `AppModel.swift` (ajustes, `now`, timer, notificações, gravação), `StatusItemController.swift` (item da barra, clique esquerdo e direito, popover, menu), `CitiesWindow.swift` (janela e views de ajustes)
- Modify: `MenuBarImage.swift` (`make(pieces:)`), `CalendarView.swift` (parâmetro `redSunday`), `LoginItem.swift` (`apply(disabledByHost:)`), `Package.swift` (`.macOS(.v14)`), `scripts/build-app.sh` (`LSMinimumSystemVersion` 14.0)

**Interfaces (Consumes):** tudo das Tasks 1 a 3, `MonthGrid`, `CalendarScript`, `MinuteTicker`.

Comportamento conforme o spec. `disabledByHost = true`: `SMAppService.mainApp.unregister()` e `exit(0)` antes de criar o item da barra.

- [ ] `swift build` sem erros nem avisos; `swift test` verde.
- [ ] `scripts/build-app.sh --install`; gravar neste Mac os ajustes TO e SP; conferir por Acessibilidade: descrição do item, menu do clique direito com os 3 itens, janela de cidades abre.
- [ ] Commit `feat(calendario): menu no clique direito, cidades e relogios configuraveis`.

### Task 5: CalendarCompanion no DictationApp

**Files:** Create `DictationApp/CalendarCompanion.swift`; Modify `DictationApp/AppDelegate.swift` (chamar `CalendarCompanion.sync()` em `applicationDidFinishLaunching`), `DictationApp/MainHubView.swift` (grupo "CALENDÁRIO" nas configurações), regenerar o projeto com `xcodegen` se o arquivo novo não entrar sozinho.

**Interfaces (Produces):**

```swift
enum CalendarCompanion {
    static var isEnabled: Bool { get set }      // UserDefaults "calendarCompanionEnabled", padrão true
    static func sync()                            // assíncrono, fora da thread principal
    // Núcleo com caminhos injetáveis, para o script de verificação:
    static func installIfNeeded(embedded: URL, installed: URL, fileManager: FileManager) throws -> Bool
}
```

- [ ] Script de verificação com pastas temporárias: instala quando ausente; não reinstala quando igual; reinstala quando o binário difere; devolve `false` sem embutido.
- [ ] `xcodebuild -scheme DictationApp -configuration Debug build` compila.
- [ ] Commit `feat(calendario): DictationApp instala e controla o calendario`.

### Task 6: Release

**Files:** Modify `scripts/release.sh`, `.gitignore` (`.build/`)

- [ ] Depois do `xcodebuild` e antes da assinatura: `RelogioDuplo/scripts/build-app.sh`, copiar para `${APP_PATH}/Contents/Resources/RelogioDuplo.app`, assinar o app embutido com o mesmo certificado.
- [ ] `bash -n scripts/release.sh`; ensaio manual dos passos novos sobre uma cópia do app em pasta temporária, com `codesign --verify --deep --strict`.
- [ ] Commit `feat(calendario): release embute o calendario`.
