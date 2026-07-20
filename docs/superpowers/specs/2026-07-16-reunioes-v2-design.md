# Reuniões v2 — Design

Data: 2026-07-16 · Status: aprovado em conversa (Diego) · Escopo: refatoração do módulo `DictationApp/Reunioes/`

## Problema

1. **Áudio do sistema mudo intermitente**: desde 13/jul, parte das reuniões grava o track de sistema
   em silêncio digital absoluto (RMS 0,000000; bitrate AAC ~2-4 kbps vs ~100 kbps normal). Causa:
   defeito de rota do ScreenCaptureKit; o mecanismo de recuperação atual nunca dispara quando o
   silêncio começa junto com a gravação (`audibleBuffers > 0` exigido) e é lento (60s+30s).
2. **Sem percepção durante a reunião**: o usuário não está olhando o app; descobre a falha só depois.
3. **Sem proteção contra crash**: gravação de 11/jul perdeu 66MB (m4a sem moov, imperdível).
4. **Player limitado**: janela pequena, sem relógio posição/duração, difícil achar trechos.
5. **Sem edição**: não há como aparar início/fim nem remover trechos (ex.: esqueceu de parar).
6. **Visual defasado**.

## Decisões do usuário

- Cortes **preservam o original** (pasta de backup, 30 dias).
- **Nenhum** HUD permanente durante gravação normal; alerta **salta à frente só em problema**.
- Entrega em fases: **Fase 1 = confiabilidade**, Fase 2 = player/edição/visual.

## Fase 1 — Confiabilidade

### 1.1 Captura do áudio do sistema via Core Audio process tap
- Novo `SystemAudioTapCapture`: `CATapDescription` global (excluindo o próprio processo) +
  `AudioHardwareCreateProcessTap` + aggregate device + IOProc → `AVAudioPCMBuffer`.
- Escritor unificado baseado em `AVAudioFile` (mesmo caminho do mic), aposentando o
  `MeetingTrackWriter`/CMSampleBuffer para o novo caminho.
- **Fallback automático** para o caminho SCK atual se o tap falhar (permissão/OS antigo).
- Permissões: nova linha "Gravação de Áudio do Sistema" (prompt próprio no macOS 14.4+),
  mantendo a de Gravação de Tela apenas para o fallback SCK.

### 1.2 Detecção e recuperação de silêncio
- Detector conta zeros digitais desde o **primeiro buffer** (sem exigir áudio audível prévio).
- 10s de zero absoluto → **restart silencioso** da captura (transparente).
- Persistindo mais 10s após o restart → **alerta** (1.3). Reset ao voltar áudio audível.

### 1.3 Alerta que salta à frente (única UI durante gravação)
- `NSPanel` flutuante (`.floating`, todas as Spaces, `orderFrontRegardless`), estilo do HUD do
  ditado (fundo escuro, borda, vermelho de gravação): título "Sem áudio do Mac há Xs",
  botões **Reiniciar captura** e **Ignorar** (silêncio legítimo). Também dispara em erro fatal
  de gravação (engine parou). Some sozinho quando o áudio volta.

### 1.4 Gravação à prova de crash
- Durante a gravação, tracks em **CAF/AAC** (container tolerante a corte abrupto).
- No stop: remux CAF → .m4a e remoção do CAF.
- No launch: varredura de CAFs órfãos de sessões mortas → recuperação automática para .m4a e
  entrada na lista com sufixo "(recuperada)".

## Fase 2 — Player, edição e visual

- Janela maior/redimensionável; timeline com régua de tempo, relógio `posição / duração`,
  clique/arraste para buscar, zoom na waveform.
- **Cortes**: seleção de intervalo na timeline → aparar início/fim ou remover trecho do meio,
  aplicado em sincronia nos dois tracks (`AVMutableComposition`) e com timestamps da transcrição
  deslocados. Original vai para `Meetings/Backup/` com data; limpeza após 30 dias.
- Higiene da lista: gravações < 5s marcadas como abortadas com remoção em um clique.
- Refresh visual dos cards/lista/tipografia alinhado ao estilo do HUD novo (dark, azul royal).

## Fora de escopo

- Reparo do m4a corrompido de 11/jul (exige cirurgia de mp4; avaliar depois, com untrunc).
- Diarização multi-falante dentro do track de sistema (fica como está: "Você"/"Outros").

## Critérios de aceite (Fase 1)

1. Reunião gravada com fones Bluetooth e saída trocada no meio → track de sistema audível.
2. Silêncio digital desde o início → restart automático em ~10s; alerta visível na frente de
   qualquer app em ~20s; botões funcionam.
3. `kill -9` no app durante gravação → ao reabrir, a reunião aparece na lista, tocável até o
   momento da morte.
4. Ditado por voz (fn+fn) segue funcionando durante uma gravação de reunião.
