# Calendário na barra de menu (RelogioDuplo): design

Data: 2026-11-27. Decisões do Diego em conversa. Substitui o spec inicial do repositório local `~/Developer/RelogioDuplo`.

## Objetivo

1. O calendário de barra de menu (RelogioDuplo) passa a ser configurável por qualquer pessoa: cidades, quantidade de relógios, formato de hora, domingo vermelho.
2. Ele é distribuído junto com o DictationApp: a próxima release já instala o calendário.

## Calendário

App separado, `RelogioDuplo.app`, identificador `com.diegofaccipieri.RelogioDuplo`, macOS 14+, sem ícone no Dock. Fonte em `RelogioDuplo/` neste repositório.

### Barra de menu

Formato: `D - H:mm SIGLA - H:mm SIGLA ...`, um trecho por relógio, na ordem configurada.

1. `D`: dia do mês no calendário do sistema.
2. 24h: `27 - 20:41 TO - 22:41 SP`. 12h: `27 - 8:41 PM TO - 10:41 PM SP`.
3. Hora sem zero à esquerda, minutos com dois dígitos. Em 12h, meia-noite e meio-dia são `12`.
4. Sigla vazia: o trecho fica só com a hora.
5. Fuso inválido: `--:--`.
6. Aparência em negativo: placa arredondada preenchida, texto vazado, imagem template. Siglas e AM/PM em fonte menor. Dígitos de largura fixa.
7. Atualiza na virada de cada minuto, ao acordar, na mudança de relógio, de fuso e de ajustes.

### Clique esquerdo

Popover com a grade do mês: mês e ano, setas, "Hoje", iniciais dos dias, número da semana bem esmaecido (15%), 6 semanas fixas, hoje destacado, fim de semana esmaecido, dias de outros meses apagados. Clique em um dia abre esse dia no Calendar (AppleScript). Ao reabrir, volta ao mês atual. Sem rodapé e sem botão "Sair".

Domingo em vermelho (inicial e dias) quando a opção estiver ligada. Desligada, o domingo fica esmaecido como o sábado.

### Clique direito (ou Control + clique)

Menu:

1. "Cidades e relógios…": abre a janela de ajustes.
2. "Formato 24 horas": marcado ou não.
3. "Domingo em vermelho": marcado ou não.

### Janela "Cidades e relógios"

1. Lista dos relógios, na ordem da barra. De 1 a 4.
2. Cada linha: cidade (botão que abre uma lista com busca de todos os fusos do sistema), sigla (texto, até 4 caracteres, maiúsculas), mover para cima, mover para baixo, remover.
3. "Adicionar relógio": cria uma linha com a cidade do fuso do Mac. Desabilitado com 4.
4. Remover fica desabilitado quando só há 1 relógio.
5. Ao escolher uma cidade, a sigla é sugerida: iniciais das palavras (São Paulo: `SP`, New York: `NY`) ou as duas primeiras letras (Toronto: `TO`), sem acentos.
6. Mudanças valem na hora e são salvas.

### Ajustes

Guardados em `UserDefaults` do calendário, chave `settings`, JSON em texto. Padrão de quem instala: um relógio com a cidade do fuso do Mac, 24h, domingo vermelho ligado. JSON ilegível: volta ao padrão.

### Login e controle pelo DictationApp

1. Ao iniciar, o calendário lê a chave `disabledByHost` do próprio domínio.
2. `false` ou ausente: registra-se no login (`SMAppService.mainApp`) e roda.
3. `true`: remove o registro do login e encerra.

## DictationApp

1. Opção nova em Configurações: "Calendário na barra de menu", ligada por padrão (`calendarCompanionEnabled`).
2. Ao iniciar e ao mudar a opção, roda a sincronização:
   1. Ligada: se existir `RelogioDuplo.app` embutido em `Contents/Resources` e o instalado em `/Applications` estiver ausente ou com binário diferente, fecha o calendário, substitui e reabre. Grava `disabledByHost = false`. Abre o calendário se não estiver rodando.
   2. Desligada: grava `disabledByHost = true`, fecha o calendário e o abre uma vez para ele sair do login. Não apaga o app.
3. Sem app embutido (build de desenvolvimento): não instala nada; o resto funciona se o calendário já estiver instalado.
4. Falhas vão para o log e não interrompem o DictationApp.

## Release

`scripts/release.sh` passa a compilar o calendário, copiar para `DictationApp.app/Contents/Resources/RelogioDuplo.app` e assinar com o mesmo certificado, antes da assinatura do app principal. O atualizador não muda.

## Fora do escopo

Mais de 4 relógios, eventos na grade, escolha de cores, segundos, desinstalação automática do calendário.

## Testes

Unitários no pacote `RelogioDuplo` (lógica pura): texto da barra com 1 a 4 relógios, 12h e 24h, sigla vazia, fuso inválido, horário de verão; ajustes (padrão, limites, gravação e leitura, JSON ilegível); catálogo de cidades (busca sem acento, sugestão de sigla); grade do mês; script do Calendar.

`CalendarCompanion` do DictationApp: caminhos injetáveis, exercitado por um script com pastas temporárias. Compilação do DictationApp verificada com `xcodebuild`.

Manual, com o Diego: cliques, menu, janela de cidades, opção no DictationApp.
