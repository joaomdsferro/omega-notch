# TODO — próximas 15 features

Ordem pensada para fechar primeiro o que está a meio, depois ganhar confiança nos
dados, só então investir na interação que justifica o notch. Esforço: **S** ≤ 1 dia,
**M** 2–4 dias, **L** 1+ semana. Cada item diz quando está pronto.

## A. Fundação — fechar o que já está começado

1. **CI de paridade macOS** · M
   Compilar o shell macOS e correr `swift test` no CI, e resolver os pontos
   abertos no `docs/design/HANDOFF.md` (ThemeStore, RingView, loading, estados).
   *Pronto quando:* um PR que parte o Swift falha no CI, e o HANDOFF deixa de ter
   itens "por compilar".

2. **Loading state no dashboard Plasma** · S
   `Q_PROPERTY(bool dashboardLoading)` no `engineclient`, marcado em
   `requestDashboard()` e limpo em `applyDashboard()`, usado nos estados vazios.
   *Pronto quando:* abrir o dashboard com o engine lento mostra "Loading…" e não
   o estado vazio, tal como no macOS.

3. **Estados de erro e de limite esgotado ao nível da página** · M
   Hoje só existe o "engine offline" genérico e o limite dentro do cartão do
   provider. Falta uma página de erro do dashboard e um estado de quota a 100%.
   *Pronto quando:* um dashboard falhado tem uma acção de retry, e um provider a
   100% lê-se na página, não só no anel.

4. **Teclado, foco e reduced motion no Plasma** · M
   Os controlos do dashboard são `TapHandler` e não são focáveis; o picker de
   temas já é. Ler o ajuste de movimento do sistema ou declará-lo em Settings.
   *Pronto quando:* se navega o dashboard inteiro só com Tab/Enter/Esc e há anel
   de foco visível em todos os controlos.

5. **NOIR ao nível do componente** · M
   Elevação por traço (1 px + realce no topo) em `DashCard.qml` e
   `DashboardParts.swift`, a escala tipográfica completa do `DESIGN.md`, e uma
   curva de movimento única nos dois shells.
   *Pronto quando:* os dois shells usam os mesmos degraus e a mesma curva, e o
   `check_themes.py` cobre também tipo e movimento.

## B. Confiança nos dados

6. **Proveniência e frescura de cada leitura** · M
   Cada leitura passa a dizer de onde veio e há quanto tempo: oficial, em cache,
   estimado, sem dados. Painel "Doctor" em Settings que explica o que cada
   provider consegue ver (reaproveita o `make doctor`).
   *Pronto quando:* o card e o dashboard distinguem uma leitura de 3 minutos de
   uma de ontem, e um provider sem dados diz porquê.

7. **Burn-rate e previsão de reset** · M
   Projecção linear da janela actual: "a este ritmo chegas ao limite às HH:MM" e
   "vais ficar sem quota antes do reset". Visível no card e no dashboard.
   *Pronto quando:* a previsão aparece só com dados suficientes, é marcada como
   estimativa, e nunca substitui o número oficial.

8. **Custo honesto** · M
   Mostrar o que pagas (subscrição prorrateada ao período) antes do equivalente
   em API, cache miss/rebuilt, e custo por prompt nas sessões mais caras.
   *Pronto quando:* o dashboard responde "porque é que este prompt custou isto"
   sem sair da linha da sessão.

9. **Orçamentos locais e histórico de quota** · M
   Cap diário/mensal com notificação local, e guardar a utilização das janelas ao
   longo do tempo para responder "quantas vezes é que bateste no limite".
   *Pronto quando:* defines um cap em Settings, recebes um aviso ao cruzá-lo, e o
   histórico mostra a tendência de quota sem guardar conteúdo de chats.

## C. Interacção — o que o menu bar não faz

10. **Aprovações inline no notch** · L
    Pedido de permissão do Claude Code via hook long-poll, com Allow / Allow
    always / Deny no notch e a decisão devolvida ao CLI. Um shell primeiro (o
    Plasma, por ser onde consegues testar), depois o outro.
    *Pronto quando:* uma sessão bloqueada num pedido é resolvida sem ir ao
    terminal, e a decisão "always" é respeitada.

11. **Fila única "Precisa de ti"** · M
    Waiting, aprovações e perguntas de todos os providers numa lista ordenada por
    urgência, com badge no nub e no anel do provider.
    *Pronto quando:* uma sessão de outro provider a pedir algo aparece ao lado
    da do Claude Code, com a mesma prioridade.

12. **Foco tab-accurate** · M
    Usar o `tty` que o engine já calcula para escolher a tab certa (Terminal,
    iTerm2, Ghostty) em vez de só levantar a janela; e `--resume` quando a
    sessão já morreu.
    *Pronto quando:* clicar num chat com três tabs abertas cai na tab certa, nos
    dois terminais mais usados.

13. **Sessões ao vivo para Codex e OpenCode** · L
    Ler os rollout logs do Codex e o `opencode.db` para derivar estado
    working / waiting / done, tal como já se faz para o Claude Code.
    *Pronto quando:* os dois providers têm ring com estado e "recent chats" com
    a mesma qualidade do Claude Code.

## D. Alcance

14. **Duas máquinas num dashboard** · L
    Export/import versionado de agregados (sem conteúdo de chats) e merge
    idempotente por provider/dia/modelo; sincronização por pasta, LAN ou
    Tailscale, sem conta e sem servidor.
    *Pronto quando:* o dashboard de uma máquina mostra os totais somados das
    duas, e importar o mesmo ficheiro duas vezes não duplica nada.

15. **Status e incidentes dos providers** · S
    Polling dos status pages (Anthropic, OpenAI, GitHub, Cursor) com cache de 5
    minutos, badge no anel e aviso no card quando há incidente.
    *Pronto quando:* uma falha do provider é distinguível de uma falha da tua
    rede, e o badge desaparece quando o incidente fecha.

## Fora de âmbito por agora

Skills entre providers (projecto irmão, não feature do notch), cloud/sync
hospedado, multi-conta por provider e mais providers. Nada disto entra antes de
1–9 estarem fechados.
