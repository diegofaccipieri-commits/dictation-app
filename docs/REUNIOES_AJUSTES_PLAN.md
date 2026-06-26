# Plano de ajustes — Reuniões: ouvir as duas trilhas juntas + transcrição ao vivo por chunks

> Continuação do módulo Reuniões (branch `feature/reunioes`). Dois ajustes pedidos:
> **(A)** poder ouvir microfone + áudio do sistema **ao mesmo tempo** (hoje só dá pra ouvir um por vez);
> **(B)** **transcrição ao vivo por chunks** durante a reunião (hoje só transcreve depois de parar).
> O (B) é o mais importante: sem transcrever na hora, o objetivo de "notas da reunião" não se sustenta.

Documento para o agente de codificação (Codex). Reaproveitar o máximo do que já existe.

---

## Parte A — Reproduzir as duas trilhas simultaneamente

### Problema
`MeetingPlayer` (em `DictationApp/Reunioes/MeetingWaveform.swift`) usa **um** `AVAudioPlayer` por URL e
alterna entre as trilhas. Não há como ouvir mic + sistema juntos (é assim que a reunião realmente soou).

### Solução recomendada: AVPlayer + AVMutableComposition (uma linha do tempo, as duas faixas tocando juntas)
- Ao abrir/preparar uma reunião, montar uma `AVMutableComposition` com **dois `AVMutableCompositionTrack`
  de áudio**: inserir a faixa do `_mic.m4a` e a do `_system.m4a`, ambas começando em `.zero`.
- Tocar com um único `AVPlayer(playerItem:)` → as duas faixas saem juntas, com **uma só timeline,
  play/pause, seek e um único playhead**.
- Observar o tempo com `addPeriodicTimeObserver` para mover o playhead nas duas waveforms ao mesmo tempo.
- (Opcional, fácil) `AVAudioMix` com `AVMutableAudioMixInputParameters` por faixa → **volume independente**
  (balancear "sua voz" x "os outros"). Bom de ter, não obrigatório.

### Mudanças de arquivo
- `MeetingWaveform.swift`: adicionar um modo de **reprodução combinada** ao `MeetingPlayer`
  (ex.: `playCombined(mic:system:)`, `progress` publicado, `stop()`), ou um novo
  `MeetingCombinedPlayer` baseado em `AVPlayer` + `AVMutableComposition`.
- `ReunioesView.swift` (no `MeetingCard`): adicionar um botão **"Tocar reunião"** (ou "Ambos") que toca a
  composição; manter os botões por trilha (Você / Outros) para ouvir isolado. O playhead da reprodução
  combinada deve andar nas duas waveforms.

### Alternativas (se não quiser AVPlayer/composition)
- **Dois `AVAudioPlayer` sincronizados**: iniciar ambos juntos com `play(atTime: deviceCurrentTime + delay)`.
  Mais simples, porém sem timeline única e com risco de leve drift.
- **`AVAudioEngine` com 2 `AVAudioPlayerNode` → `mainMixerNode`**: robusto e dá volume por trilha;
  mais setup.
- **Pré-mixar um `_mixed.m4a` ao parar** (export de composição): playback simples depois (um player só) e
  ainda serve de export. Pode ser feito junto, mas a composição em memória já resolve o playback.

### Critério de aceite (A)
- Existe um botão que toca **mic + sistema juntos**, em sincronia, com playhead único.
- Os botões de ouvir cada trilha isolada continuam funcionando.

---

## Parte B — Transcrição AO VIVO por chunks (durante a gravação)

### Motivação
Hoje a transcrição é só pós-gravação (`WhisperCppCLI.transcribeSegments` no arquivo final). Para "notas da
reunião" fazer sentido, a transcrição precisa **ir aparecendo durante a reunião**, em pedaços (chunks).

### O que JÁ existe e deve ser reaproveitado
- **`WhisperCppServer`** (em `DictationApp/WhisperCpp.swift`): sobe o binário `whisper-server` (porta 8178),
  **mantém o modelo carregado**, e tem `func transcribe(samples: [Float]) async -> String` que recebe
  **16 kHz mono Float** e devolve o texto via HTTP `/inference`. **Esta é exatamente a API de chunk ao vivo.**
  Métodos: `start()`, `waitUntilReady(timeout:)`, `transcribe(samples:)`, `stop()`.
- **`WhisperCppCLI.transcribeSegments`**: o passo final de alta qualidade (continua sendo usado no fim).
- O ditado ao vivo já usa esse servidor — a engine de chunk já está provada.

### Desenho
```
Durante a gravação:
  Mic (AVAudioEngine tap)      ─► resample 16k mono ─► micRing  ─┐
  Sistema (SCStream .audio)    ─► resample 16k mono ─► sysRing  ─┤
                                                                 ├─► Chunker (a cada ~6-8s, ou em silêncio/VAD)
                                                                 │     pega o trecho acumulado de cada trilha
                                                                 │     ─► WhisperCppServer.transcribe(samples:)
                                                                 │     ─► emite MeetingSegment provisório
                                                                 └─►   (mic→"Você", sistema→"Outros"), com timestamp
  UI: painel de transcrição AO VIVO, balões aparecendo em estilo "provisório" (cinza/itálico)

Ao parar:
  Passo final canônico: MeetingTranscriber (WhisperCppCLI no arquivo cheio) ─► SUBSTITUI a transcrição
  provisória pela definitiva ─► persiste JSON. (Desenho "ao vivo + final".)
```

### Pontos de implementação
1. **Expor o áudio ao vivo na captura** (`MeetingCaptureEngine.swift` / `MeetingMicrophoneCapture`):
   - Sistema: em `stream(_:didOutputSampleBuffer:of:)` (caso `.audio`), além de escrever no arquivo,
     converter o buffer para **16 kHz mono Float** e empurrar num ring buffer `systemLive`.
   - Microfone: no tap do `AVAudioEngine`, converter para 16 kHz mono Float e empurrar em `micLive`.
   - Usar `AVAudioConverter` para o resample (sistema costuma vir 48 kHz estéreo).
   - Marcar o tempo de início de cada chunk (relativo ao começo da gravação) para os timestamps.
2. **`MeetingLiveTranscriber`** (novo, `@MainActor ObservableObject`):
   - Garante o `WhisperCppServer` rodando e pronto (`start()` + `waitUntilReady()`), mostrando
     "preparando modelo..." se precisar aquecer.
   - Loop a cada ~6-8s (ou disparado por VAD/silêncio): pega o trecho novo de cada ring, e se tiver energia
     suficiente (gate simples de VAD para não transcrever silêncio e evitar alucinação), chama
     `server.transcribe(samples:)`.
   - **Fila serial** para os dois fluxos (mic e sistema) já que o servidor atende um request por vez.
   - Emite `MeetingSegment(speaker: Você/Outros, text:, start:, end:)` provisório e adiciona ao
     transcript exibido ao vivo.
3. **Reconciliação ao parar**: chamar o `MeetingTranscriber` existente (passo `WhisperCppCLI` no arquivo
   cheio) e **substituir** os segmentos provisórios pelos definitivos; persistir o JSON final.
4. **UI (`ReunioesView.swift`)**: durante a gravação, mostrar o painel de transcrição ao vivo
   (balões Você/Outros em estilo provisório + indicador "ao vivo"); ao parar, vira a versão final.

### Decisões / parâmetros sugeridos
- Tamanho do chunk: **6-8s**. Para não cortar palavra: preferir cortar num **silêncio curto** dentro da
  janela (VAD por energia), ou usar **overlap** (~1s) e deduplicar. Começar fixo + `--split-on-word` (já
  ligado no servidor) e refinar depois.
- Idioma: `auto` (PT/EN), igual ao resto.
- Latência esperada: alguns segundos por chunk (transcreve em ~1-3s na GPU) — aceitável para "ao vivo".

### Edge cases / cuidados
- **Porta 8178 / instância única**: o `whisper-server` é por app. **Nunca rodar duas instâncias** do app
  (foi o que derrubou o ditado). Reaproveitar um único servidor; serializar os requests do mic e do sistema.
  Se houver risco de conflito com o ditado ao vivo, considerar uma **porta dedicada** para a reunião (ex.: 8179)
  com um `WhisperCppServer` próprio, parando-o ao fim da reunião.
- **Silêncio**: não enviar chunks sem fala (gate de energia) para evitar texto fantasma.
- **Aquecer o modelo** ao abrir a janela/iniciar a gravação (mostrar status).
- **Custo**: transcrever ao vivo enquanto grava + os dois fluxos é ok no Apple Silicon (Metal), mas medir.
- Encerrar o servidor/limpar quando a reunião acabar (higiene de processo).

### Critério de aceite (B)
- Durante a reunião, o texto vai aparecendo em poucos segundos após a fala, rotulado Você/Outros, ao vivo.
- Silêncio não gera texto.
- Ao parar, o passo final (whisper-cli no arquivo) substitui o provisório pela transcrição de alta qualidade
  e persiste.
- O ditado normal continua funcionando (uma instância, sem briga de porta).

---

## Ordem sugerida e esforço
1. **B (ao vivo por chunks)** primeiro — é o que dá sentido às notas. Reusa `WhisperCppServer`.
   - B.1 expor rings 16k na captura → B.2 `MeetingLiveTranscriber` → B.3 UI ao vivo → B.4 reconciliação final.
2. **A (playback combinado)** depois — menor, melhora a revisão da reunião.

## Higiene (repetindo, porque já mordeu)
- Build limpo em pasta dedicada; assinar com o cert `34A488...`; **uma instância só**; matar
  `whisper-server`/`whisper-cli` sobrando antes de testar.

## Próximo da fila (fora deste plano)
- Diarização real dos "Outros" (FluidAudio) e **notas com IA** a partir da transcrição (ao vivo + final).
