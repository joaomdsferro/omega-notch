# Handoff — o tema NOIR e o motor de temas

Onde a sessão parou. Ler isto primeiro.

## Manhã de 2026-10-20

**O teste que falhava à meia-noite — corrigido.** Não era um bug do produto:
o turno de teste era escrito "30 segundos atrás", e se o teste corresse a meio
da virada do dia, esse turno caía no dia anterior — logo `today` vinha a zero
e `week` não. Agora o relógio entra na função (`activity_from(conn, now)`) e o
teste usa o mesmo instante para a fixa e para o código, pelo que a virada do
dia deixou de poder estragar o teste. Há um teste novo
(`a_turn_at_the_edge_of_midnight_belongs_to_its_own_day`) que fixa o relógio
às 23:59:59 e prova que o turno conta como o dia dele. A suite passa em
UTC, Lisboa, Kiritimati, Midway, Nova Iorque e Kolkata.

**A app não arrancava** — e foi preciso a correr para o ver. Quatro erros de
QML que o `qmllint` e o compilador de cache não apanham:
- o `Theme.qml` é um `QtObject`, que não tem default property: o
  `Connections` que segue a config do engine não cabia lá. Passou a ser um
  `Item` (que nunca entra numa cena);
- `ShapePath` não tem `strokeOpacity`: a cor leva o alfa, e o alfa tem de
  *multiplicar* o que a cor já tinha (`Theme.withAlpha`);
- `font.pixelSize` é inteiro no QML (11.5 dá erro);
- o `Repeater` do QML só aceita delegates que sejam `Item`, e `ShapePath`
  não é. O medidor passou a ser geometria a sério: vinte arcos em SVG, cada
  um com a sua cor (`ProviderRing.qml`), porque o `dashPattern` do Qt
  Shapes não é desenhado.

**A app foi reinstalada e está a correr** com o NOIR por omissão
(`make install` → `~/.local/bin`; o engine foi reiniciado pelo script e o
shell foi lá com a install). Para a ver: `OMEGA_NOTCH_PREVIEW=opencode` abre a
notch com o card; `journalctl --user -f` mostra os erros de QML.

## Tarde de 2026-10-20 — a bolinha do nub, o nub e as micro-animações

**A bolinha do "por ler" era invisível.** Com o NOIR, a bolinha é o acento
(azul) e o nub é da cor que o utilizador escolheu: azul `#5B8CFF` sobre o
laranja `#FF5A36` dá **1.02:1** — praticamente não se vê. Agora a marca escolhe
a cor conforme o fundo: `Theme.markColor(surface)` (QML) e
`Theme.markColor(_:)` (Swift) põem a cor do "por ler" quando ela se lê ali
(3:1) e, se não, a tinta que se lê melhor no fundo (preto ou branco, o que
der mais contraste). No nub laranja a bolinha fica preta (6.77:1).

**Cuidado com as cores do QML:** as componentes de `color` vão de 0 a 1, não
de 0 a 255. A primeira versão da função de contraste dividia por 255 e dava
1.00 para tudo — e a bolinha saía branca em vez de preta.

**O nub** ganhou um fio de luz no bordo (`NotchShape.rim`), para não parecer
uma etiqueta chapada no desktop; o corpo da notch também o tem, mais
discreto.

**Micro-animações** (todas de transformação e opacidade, sem custo de layout):
- a bolinha do nub respira devagar (2.2 s, opacidade 0.65–1) — é o sinal de
  " há algo para ler", e assim o olho encontra-a;
- o card assenta no lugar em vez de aparecer: cresce 1.5% a partir do lado
  que olha para a notch (QML e macOS);
- o macOS passa a ter `Breathing(active:period:)`, para a bolinha poder
  respirar ao ritmo que se quiser.

**No macOS, a bolinha sobre o desktop** (quando a notch está dentro da
housing da câmara) ganhou um aro escuro e um claro: ali o fundo é o papel de
parede de quem está a usar, e não se pode presumir a cor.

## Fim de tarde de 2026-10-20 — os dois que faltavam

**Estado de loading no dashboard do Plasma.** `EngineClient` ganhou
`dashboardLoading` (ligado a `dashboardChanged`): põe-se a true quando se
pedem os números e a false quando chegam. O estado vazio dos limites e o do
gráfico de custo dizem "Loading…" em vez de fingirem que não há nada.
O macOS já tinha isto (`client.dashboardLoading`, `loadingHint`).

**Elevação por traço nos cartões.** A regra do `DESIGN.md` — 1 px de traço e
um fio de luz no topo — passou a ser o que se vê: `DashCard.qml`,
`DashLimitCard.qml` e o `Card` das Settings no Plasma; `DashCard` e
`LimitCard` no macOS. O traço passou de `hairline` para `cardStroke`, para
o cartão ter bordo de verdade, e o topo apanha um gradiente de branco a 9%
que se apaga nos primeiros 16%.

**Falta só uma coisa, e não é minha:** compilar e testar o shell do macOS.

## O que está feito

**Motor de temas (os dois shells)**
- `crates/omega-notch-core/src/config.rs`: chave `theme` na `AppConfig`, com
  `THEMES` (a lista canónica) e queda para `noir` quando o nome é desconhecido.
  Teste em `config.rs` e fixtures do protocolo actualizadas.
- `ui/plasma/qml/Theme.qml`: os tokens deixaram de ser `readonly`; há os seis
  temas em `themes` e `apply(name)` põe um tema no lugar. Segue a config do
  engine por `Connections { target: Engine }`.
- `ui/plasma/src/engineclient.{h,cpp}`: `Q_PROPERTY theme` + `setTheme()`.
- `ui/macos/Sources/OmegaNotchKit/ThemeCatalog.swift` (novo): o catálogo dos
  seis temas em hex + alfa, testável sem ecrã.
- `ui/macos/Sources/OmegaNotch/Theme.swift`: `ThemeTokens` + `ThemeStore`
  (`@Observable`) + o `enum Theme` a ler do store. O `ThemeStore` é o que as
  vistas observam, por isso mudar o tema repinta tudo sem tocar nas vistas.
- `ui/macos/Sources/OmegaNotchKit/NotchConfig.swift`: `config.theme`.
- `ui/macos/Sources/OmegaNotch/main.swift`: `trackTheme()` segue a config.
- `ui/macos/Sources/OmegaNotch/NotchPanel.swift`: o tema é posto em place
  antes do primeiro frame, para a notch não abrir noutro tema.

**O picker**
- Plasma: aba nova **Appearance** em `SettingsWindow.qml`, com os seis temas,
  as três cores de preview, `activeFocusOnTab`, `Keys.onReturnPressed` e um
  anel de foco. Ícone novo "appearance" em `SettingsIcon.qml`.
- macOS: `ThemePicker`/`ThemeRow` em `SettingsControls.swift` (botões reais,
  por isso são focáveis por teclado), aba nova em `SettingsView.swift`.

**NOIR ao nível de componente (o que se vê)**
- O anel passou de arco a **medidor de 20 segmentos**, com a zona de perigo
  (90–100%) pintada em `critical` desde o início e uma **capa especular** de
  2 px na cabeça da parte usada. O último segmento usado é cortado, para 1%
  continuar a ler-se como 1%. `ui/plasma/qml/ProviderRing.qml` e
  `ui/macos/Sources/OmegaNotch/RingView.swift`.
- O `textTertiary` deixou de reprovar AA em todos os temas (2.86:1 → 5.35:1
  no Classic; 5.40:1 no NOIR).
- `unread` deixou de ser a mesma cor que `ample` (no NOIR é o acento).
- Reduced motion no macOS: `Breathing` e `Spinning` respeitam
  `accessibilityReduceMotion` (`Theme.swift`).
- Estado de loading no dashboard do macOS: `client.dashboardLoading` e a dica
  "Loading…" em vez do estado vazio (`EngineClient.swift`, `DashboardView.swift`).

**Documentação e guardas**
- `DESIGN.md`: o sistema de design (tokens, tipos, espaço, movimento).
- `docs/design/theme-lab.html`: o mockup com os seis temas e o contraste
  calculado.
- `scripts/check_themes.py`: compara os tokens dos dois shells; ligado ao CI.

## Como verificar

```sh
cargo fmt --all --check
cargo test --workspace --locked
python3 scripts/check_themes.py
qmllint ui/plasma/qml/*.qml          # o DashUsageChart.qml já falhava antes
cmake -S ui/plasma -B /tmp/plasma-build -G Ninja && cmake --build /tmp/plasma-build
```

O shell do macOS **não compila nesta máquina** (não há Swift nem SDK da
Apple): compilar e correr os testes do macOS é o primeiro passo de amanhã.

## O que falta

1. **Compilar e testar o macOS** (`swift test` em `ui/macos`). O código novo
   de Swift não foi compilado: `ThemeStore`, `ThemeCatalog`, `ThemePicker` e o
   novo `RingView` (o `ForEach(0..<segments, id: \.self)` é o ponto mais
   duvidoso).
2. **O estado de loading no Plasma**: o macOS já tem `dashboardLoading`, o
   Plasma não. Falta `Q_PROPERTY(bool dashboardLoading ...)` em
   `engineclient.h`, marcá-lo em `requestDashboard()` e limpá-lo em
   `applyDashboard()`, e usá-lo nos estados vazios de `DashboardWindow.qml`
   (à volta das linhas 1084 e 1122).
3. **O resto do NOIR ao nível de componente**:
   - elevação por traço: `DashCard.qml` e o equivalente no macOS
     (`DashboardParts.swift`) com 1 px de traço e um realce no topo, em vez de
     cartão liso;
   - a escala tipográfica de `DESIGN.md` (falta o degrau 16–25 e o 17 como
     título de secção) — `font.pixelSize` está espalhado por ~150 lugares no
     QML e ~100 no Swift;
   - a curva de movimento única (`cubic-bezier(.22,.61,.36,1)`): o Plasma usa
     linear em `Behavior on color`, o macOS `easeOut`.
4. **O resto dos estados**: falta o estado de erro do dashboard (só existe o
   genérico "engine offline") e o estado de limite esgotado ao nível da
   página (hoje só existe dentro do cartão do provider).
5. **O teclado no Plasma**: os controlos do dashboard são todos
   `TapHandler` e não são focáveis. O picker de temas já é; o resto do
   dashboard ainda não.
6. **O `reduced motion` no Plasma**: o Qt não o dá de série; ou se lê o
   ajuste do sistema, ou se deixa estar.

## Notas

- O visual antigo ficou como o tema **Classic**; o **NOIR** é o por omissão.
  Foi uma decisão do João, não um accidents.
- A app e o engine em `~/.local/bin` estão **actualizados** (a install de
  2026-10-20). O `config.json` ficou com `"theme": "noir"`.
- `crates/omega-notch-core/src/opencode.rs` (trabalho do João) tem agora o
  relógio como argumento; o teste da meia-noite está corrigido.
- O `qmllint` **não** apanha os erros de QML acima: a app tem de ser
  corrida e o `journalctl --user` lido. O mesmo se aplica ao shell do
  macOS, que ainda nem foi compilado.
