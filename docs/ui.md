# Interface

## Princípios

- Terminologia: a UI chama a entrada processada de "MicBoost". O nome "BlackHole 2ch" só aparece onde o usuário precisa reconhecê-lo: ao escolher o microfone dentro de um app que não segue a entrada do sistema, e quando o driver está ausente.

- A aparência e o comportamento nativos são a diretriz para toda a interface: usar o componente nativo sempre que existir um que atenda, com métricas e cores do sistema; nada desenhado ou imitado. Personalização só onde não há equivalente nativo, com o motivo registrado aqui. No menu da barra, ações e listas são `NSMenuItem` reais e os controles dentro de views de item são AppKit; nenhum controle SwiftUI vive dentro do menu. Ações de menu ficam em texto, switches usam o estilo do sistema e campos mantêm os comandos padrão de edição.
- Parecer parte do sistema: materiais, tipografia (fonte do sistema, tamanhos de controle `.regular`/`.small`), espaçamento e cantos dos módulos de Som/Bluetooth da Central de Controle; ícones SF Symbols; sliders, switches e listas nativos.
- Sem aparência de mixer de estúdio e sem animações contínuas. Os medidores são o único elemento atualizado periodicamente, e só com o painel visível.
- Toda a UI vem do `AppModel` (`@Observable`, `@MainActor`), que reflete o `EngineStatus` e encaminha comandos ao `EngineController`. A UI nunca chama a HAL.
- Idiomas: pt-BR e en, via `Localization/{en,pt-BR}.lproj/Localizable.strings` nos recursos do target `MicBoostUI`, usando `NSLocalizedString` com `Bundle.module` (recursos nativos suportados pelo SwiftPM). Idioma de desenvolvimento: en.

## Item da barra de menus

- `NSStatusItem` de largura variável com imagem template monocromática de 24 × 18 pt,
inspirada no ícone do aplicativo: microfone SF Symbol e três barras ascendentes
arredondadas à direita. O sistema define a cor conforme a barra de menus. Estados:
  - `mic.fill` + barras: rodando;
  - `mic.slash.fill` + barras: mudo;
  - `mic` + barras cortadas por uma diagonal: processamento desligado (tem prioridade sobre alertas);
  - `exclamationmark.triangle.fill`, sem barras e na mesma área: erro ou divergência da entrada padrão.
- Clique (esquerdo ou direito) abre e fecha o painel. ⌥-clique liga ou desliga o processamento direto, sem abrir o painel. O rótulo de acessibilidade descreve o estado (por exemplo, "MicBoost, ativo, +12 dB").

## Painel

`NSMenu` padrão do AppKit, montado por `PanelMenuController` a partir do `AppModel`. Ações, listas e títulos são itens de menu reais; só os elementos que a Apple também hospeda em views de item (cabeçalho, faixa de estado, ganho, medidores, roteamento e equalizador) são `NSMenuItem` com uma view, e essa view é AppKit pura (`NSStackView`, `NSSlider`, `NSSwitch`, `NSTextField`, `NSButton`, `NSLevelIndicator`, `NSBox`).

- moldura, material, transparência, sombra e cantos desenhados pelo próprio menu, sem camadas de fundo adicionais;
- aberto sob o `NSStatusBarButton`, alinhado à direita e limitado à tela pelo AppKit;
- fechamento, navegação por setas, seleção por digitação, Escape e clique fora gerenciados pelo AppKit;
- hover, foco de teclado e VoiceOver dos itens de menu vêm do AppKit; nenhum destaque é desenhado pelo app;
- o delegate inicia os medidores ao abrir e os cancela ao fechar;
- entrada no tracking pelo run loop para não manter um job de concorrência Swift ocupado;
- o menu não reserva a coluna de marcação (`showsStateColumn = false`): nenhuma linha começa num vão vazio, e as linhas de view começam na mesma coluna do título de um item nativo;
- items de view: a view preenche a largura do menu (`autoresizingMask = .width`) e o conteúdo começa e termina nas mesmas insets do título de um `NSMenuItem` padrão. Essas insets são medidas do próprio menu na primeira abertura (o `x` do título de um item sem imagem e a coluna do atalho) e ficam guardadas em `UserDefaults.menuRowInsets`, para o painel abrir já alinhado nas execuções seguintes. Um item de view não recebe a ação do menu ao ser clicado: a linha de microfone trata o `mouseUp`, fecha o menu e chama `performActionForItem(at:)`, como um item nativo;
- os sliders são `NSSlider`: o controle conduz o próprio laço de arrasto e continua respondendo dentro do tracking do menu, enquanto o gesto do `Slider` do SwiftUI perde o mouse-up fora da view hospedada e deixa o slider preso no estado pressionado. As atualizações são contínuas durante o arrasto, sem marcas de passo, e o knob só acompanha valores externos (campo numérico, teclado, persistência) quando não há arrasto.

**Fechar o painel nunca afeta o motor.** Aparência e preferências de acessibilidade
são herdadas do sistema. Não alterar o fundo, recorte ou opacidade da janela do menu.

Itens, de cima para baixo:

1. **Cabeçalho (view):** no mesmo layout do topo dos menus de Wi-Fi e Bluetooth do macOS: título "MicBoost" em negrito à esquerda e um `NSSwitch` nativo à direita, controlando o processamento (`processingEnabled`). Fica sempre visível no topo e alcançável com um clique ao abrir o painel. É o jeito principal de parar o MicBoost e **soltar o microfone**:
   - **Desligar:** para o motor por completo (rampa, `AudioDeviceStop`, IOProc e agregado destruídos), de modo que o microfone deixa de ser capturado e o indicador de microfone do macOS apaga. A entrada padrão é restaurada conforme a [política](audio-engine.md#política-de-entrada-padrão-defaultinputmanager), e o ícone vira `mic`.
   - **Ligar:** reconstrói o motor com a fonte e os ajustes persistidos e reaplica a política de entrada padrão.
   - O estado persiste (`processingEnabled`), e a troca nunca fecha o painel.
2. **Faixa de estado (view):** um item que só existe no menu enquanto há mensagem (ver [Mensagens de estado](#mensagens-de-estado)). O aviso usa `NSBox` como fundo, um texto secundário e o botão da ação; ações de documentação são `NSButton` sem borda com título na cor de destaque, e as de nova tentativa usam o botão arredondado do sistema.
3. **Ganho (view):** botão de mute sem borda com o ícone `mic.fill`/`mic.slash.fill` centralizado em uma área fixa de 20 × 20 pt para não deslocar o slider ao alternar, slider nativo de ganho de −12 a +24 dB e rótulo `398% (+12,0dB)` (percentual primeiro; dB entre parênteses). O valor é texto somente leitura, sem campo e sem ação de clique: o ganho se ajusta pelo slider e pelas setas do teclado. O selo "Limitador ativo" (`NSBox` com cantos arredondados) aparece ao lado do valor de ganho durante a proteção de pico; sua área permanece reservada e o selo fica oculto para acessibilidade quando inativo, sem alterar a altura do painel ou deslocar controles.
4. **Medidores (view):** duas linhas, "Entrada" e "Saída", com rótulo em `.caption` e um `NSLevelIndicator` nativo ao lado (ver [Medidores na UI](#medidores-na-ui)).
5. **Separador** nativo (`NSMenuItem.separator()`).
6. **Entrada do sistema (view):** apenas o estado da entrada padrão; a fonte selecionada é indicada pelo selo na lista de microfones, sem uma linha adicional de caminho do áudio:
   - entrada padrão no BlackHole 2ch: "Entrada do sistema: MicBoost", com a marcação de verificação apenas enquanto o motor está rodando; o nome "BlackHole" nunca aparece na linha, qualquer que seja o estado do motor;
   - divergência: "Entrada do sistema: <nome>" com o botão "Usar MicBoost", habilitado quando o clique funciona (o motor já iniciou e o BlackHole está presente), mesmo com o motor parado;
   - entrada padrão desconhecida: "Entrada do sistema: Desconhecida", sem botão;
   - com `manageDefaultInput` desligado, a linha só informa a entrada atual, sem tratá-la como divergência; o botão "Usar MicBoost" aparece se a entrada não for o BlackHole.
7. **Cabeçalho de seção "Microfone"** nativo (`NSMenuItem.sectionHeader(title:)`).
8. **Microfone:** um `NSMenuItem` com view por fonte elegível, no desenho das listas de dispositivos dos menus de Wi-Fi e Bluetooth: o símbolo SF do transporte em um selo circular de 18 pt, preenchido com a cor de destaque quando a fonte está selecionada e neutro nas demais, seguido do nome. O destaque de hover, a seleção por setas e o VoiceOver são os do menu; a linha não pinta fundo nem cria cor de hover, só acompanha o item destacado trocando o texto para a cor de seleção do sistema. Selecionar troca a fonte (reconstrução do motor com rampa). Uma fonte persistida que não está conectada aparece como um item desabilitado "<nome> (desconectado)" com o último nome conhecido daquele UID, guardado em `Settings.knownSourceNames` para sobreviver a um relançamento com o dispositivo ausente; se o nome nunca foi visto, a linha mostra "Microfone desconectado". O UID do dispositivo nunca aparece na interface.
9. **Separador** nativo.
10. **Equalizador (duas views):** o cabeçalho é um `NSButton` de disclosure nativo (triângulo) com o título "Equalizador" e um `NSSwitch` "Ativar EQ" sempre visível à direita, independente da expansão. O estado de expansão persiste (`eqExpanded`); clicar no triângulo ou no título alterna, e alternar o switch não expande nem recolhe os ajustes. Apenas as bandas e ações ficam na área recolhível:
    - Graves: slider de ganho (dB) + campo de frequência (Hz);
    - Médios: slider de ganho + campo de frequência + slider "Largura" com o valor de Q mostrado (Q maior = banda mais estreita);
    - Agudos: slider de ganho + campo de frequência;
    - ações "Padrão de voz" e "Zerar EQ" em `NSButton` arredondado do sistema, na mesma linha. Botões em vez de itens de menu porque agem sobre a seção que está aberta, sem fechar o painel, como as ações dentro dos painéis de Som do macOS; itens de menu fechariam o menu e esconderiam o resultado.
    - Cada banda é um bloco separado por espaçamento e por um separador `NSBox`, com título em negrito e marcação de cabeçalho para acessibilidade. O controle de largura fica dentro do bloco de Médios. O ganho de cada banda aparece numericamente junto ao título; campos de frequência têm largura compacta e alinhamento numérico à direita.
    - Valores editáveis, validados e limitados às faixas de [dsp.md](dsp.md#equalizador). Sem gráfico de resposta.
11. **Separador** nativo.
12. **"Ajustes…"** (⌘,) e **"Sair do MicBoost"** (⌘Q): `NSMenuItem` reais, em texto puro como "Settings…" nos menus da Apple, com atalho, hover e destaque do menu. O macOS 27 desenha ícones automáticos nesses itens; `preferredImageVisibility = .hidden` mantém o texto puro. Abrir os ajustes fecha o painel.

O menu não tem largura fixa: ela vem do item mais largo (as views têm 320 pt de referência e crescem junto com o menu). O menu AppKit só assume uma nova altura quando a lista de itens muda; esconder um item deixa o espaço dele. Por isso a faixa de estado, a linha de microfone desconectado e as bandas do EQ são inseridas e removidas durante o tracking, em vez de apenas ocultadas.

### Mensagens de estado

Uma faixa no topo do conteúdo, abaixo do cabeçalho, mostra uma mensagem por vez, na ordem de prioridade:

| Estado | Mensagem | Ação |
|---|---|---|
| `microphonePermissionDenied` | "O MicBoost não tem acesso ao microfone." | "Abrir Ajustes de Privacidade" → `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| `blackHoleMissing` | "BlackHole 2ch não encontrado." | "Como instalar" (abre a documentação de instalação) |
| `sourceUnavailable` / `recovering(.sourceLost)` | "<nome> desconectado. O áudio volta quando ele for reconectado." | escolher outro microfone na lista (sem botão) |
| `noSourceSelected` | "Escolha um microfone na lista." | escolher um microfone na lista (sem botão) |
| `formatUnsupported` | "Formato do <nome> não suportado." | escolher outro microfone (sem botão) |
| `halFailure` / `recovering(.wakeFailed)` | "Falha no áudio do sistema." | "Tentar novamente" |
| divergência da entrada padrão | (na linha de roteamento) | "Usar MicBoost" |

Uma ausência de dispositivo (`sourceUnavailable`, `recovering(.sourceLost)` e `blackHoleMissing`) só vira faixa depois de durar 1,5 s: o reinício do `coreaudiod` faz os dispositivos sumirem por um instante e não pode piscar mensagem. Se a condição terminar antes disso (o motor volta a `running` ou entra em outra recuperação), a faixa é descartada. Permissão negada, formato não suportado e falha de HAL aparecem na hora. A mesma carência vale para o que depende da lista de dispositivos: a linha de entrada do sistema mantém o último estado conhecido e a lista de microfones mantém as últimas linhas enquanto todos os dispositivos estão ausentes; passado o tempo, ambas mostram o estado real.

`recovering(.formatChanged)`, `recovering(.serviceRestarted)` e `recovering(.sleep)` são transitórios e não mostram faixa. A mensagem de fonte desconectada usa o nome do microfone quando ele é conhecido, inclusive o último nome persistido depois de um relançamento com o dispositivo ausente. A permissão de microfone é reavaliada sempre que o app volta a ficar ativo: se ela foi concedida nesse meio-tempo, o app limpa a mensagem e tenta iniciar de novo; se foi negada com o processamento ligado, a mensagem aparece.

### Medidores na UI

`NSLevelIndicator` com o estilo `continuousCapacity`, no tamanho de controle `.small`, é o **indicador de nível nativo**: o AppKit define altura, curvatura, contraste e o preenchimento, sem trilha desenhada pelo app. A cor de preenchimento é a cor de destaque do sistema (`fillColor`, `warningFillColor` e `criticalFillColor` = `controlAccentColor`), reaplicada quando as cores do sistema ou a aparência efetiva mudam, de modo que o medidor acompanhe o mesmo destaque dos sliders e switches. `warningValue` e `criticalValue` ficam acima do máximo, então a barra nunca fica amarela ou vermelha — o app já mantém o teto de pico e não avisa saturação. O medidor é só exibição: ignora cliques e arrastos, que ficam com a linha, e nunca recebe o foco do teclado.

`MeterPoller` (main actor) lê `mb_engine_read_meters` por meio do controller a 20 Hz, só enquanto o painel está visível, e aplica decaimento visual de 20 dB/s calculado a cada leitura. Subidas usam o pico da leitura seguinte; apenas a queda é gradual (30 dB levam 1,5 s). Essa duração visual é independente da latência do áudio. Com "Reduzir movimento", não há interpolação: cada leitura é exibida diretamente. O comprimento da barra usa amplitude linear (`10^(dBFS/20)`, limitada a 0…1, zero em −60 dBFS ou menos); 0 dBFS preenche a barra, o teto de −1 dBFS corresponde a 89,13% dela. Os valores de acessibilidade são o nível em dBFS de −60 a 0 e não interpolam progresso. As barras representam os picos reais antes do EQ e depois do limitador, e não uma projeção do ganho escolhido. Com EQ plano e sem redução do limitador, ganho de 200% produz uma barra de saída duas vezes maior que a de entrada.

## Janela de ajustes

`NSWindow` de 540 pt de largura com SwiftUI `SettingsView` (`Form` com estilo `.grouped`), aberta por "Ajustes…" ou ⌘, com o painel focado. Numa janela comum, o SwiftUI é desenhado pelo AppKit: cartões agrupados, switches, seletores, links e botões são os controles do sistema, sem nenhum desenho próprio. Seções:

- **Áudio:** chave "Usar MicBoost como entrada do sistema automaticamente" (`manageDefaultInput`, ligada por padrão), com uma frase explicando que, desligada, cada app precisa selecionar o microfone "BlackHole 2ch" por conta própria; "Buffer (quadros)" (64/128/256/512/1024, só os valores suportados), com descrição abaixo explicando que valores menores reduzem o atraso e valores maiores podem evitar cortes ou estalos; manter o padrão se o áudio estiver estável e modo de canais da fonte atual ([audio-engine.md](audio-engine.md#canais)), com uma linha de legenda para cada opção disponível: Mono 1 (padrão), Mono 2 e demais canais mono em ordem crescente, Misturar e Estéreo. Mono N usa o canal N nos dois lados; Misturar combina todos; Estéreo separa os canais 1 e 2 em esquerda e direita. A lista e as legendas seguem essa ordem; Estéreo só aparece com dois ou mais canais. A lista de buffers mantém todas as opções quando a fonte não informa a faixa de buffer, e uma seleção persistida que o dispositivo não oferece aparece como a opção mais próxima. Um canal persistido acima da contagem da fonte aparece como o último canal, e Estéreo em fonte de um canal aparece como Mono 1. Nenhuma das duas listas fica com o seletor vazio.
- **Diagnóstico** (somente leitura, atualização a 1 Hz com a janela visível): taxa de amostragem, buffer, latência reportada, overloads, `input_missing`, `nonfinite_resets`. Botão "Copiar relatório" (texto para a área de transferência).
- **Sobre:** versão, link do projeto, botão "Apoiar no Buy Me a Coffee" (abre `https://www.buymeacoffee.com/vittau` no navegador padrão) e licença (GPL-3.0). O botão é `Button` padrão, sem cor de marca nem logotipo.

## Componentes

Cada elemento do menu e da janela de ajustes, e o que o desenha:

| Elemento | Implementação |
|---|---|
| Cabeçalho do painel (título + switch) | view AppKit: `NSTextField` + `NSSwitch` |
| Faixa de estado (texto, ação) | view AppKit: `NSBox`, `NSTextField`, `NSButton` |
| Mute, "Usar MicBoost", disclosure, "Padrão de voz", "Zerar EQ" | `NSButton` nativo |
| Sliders de ganho, EQ e largura | `NSSlider` (`MenuSliderControl`, só para o passo de teclado) |
| Valor de ganho | `NSTextField` somente leitura (rótulo) |
| Campos de frequência | `NSTextField` editável (borda arredondada do sistema) |
| Selo do limitador e fundo da faixa | `NSBox` com preenchimento do sistema |
| Medidores de entrada e saída | `NSLevelIndicator` (`continuousCapacity`, `.small`) |
| Lista de microfones | `NSMenuItem` com view AppKit: selo circular (camada com `controlAccentColor`) e `NSTextField` |
| "Ajustes…", "Sair do MicBoost", cabeçalhos de seção e separadores | `NSMenuItem` nativos |
| Textos de estado e rótulos | `NSTextField` |
| Ajustes: seções, switch, seletores, links, botões, linhas de diagnóstico | SwiftUI sobre AppKit (`Form` `.grouped`, `Toggle`, `Picker`, `Link`, `Button`, `LabeledContent`) |

Não há nenhum controle desenhado ou imitado: todos os elementos usam controles do sistema, com as cores e métricas do AppKit, e nenhuma exceção permanece registrada.

## Teclado e acessibilidade

- O menu navega como qualquer menu do sistema: setas e seleção por digitação vão de item a item, e os itens de view recebem o destaque do AppKit.
- Sliders e campos de view de item recebem o teclado quando clicados: as setas ajustam o slider (ganho em passos de 0,5 dB, 1 dB com ⌥; EQ em 0,5 dB; largura em 0,1 de Q) e o campo de frequência anda 1/12 de oitava.
- ⌘Q encerra o app e ⌘, abre os ajustes; campos de texto usam Recortar/Copiar/Colar/Selecionar Tudo do menu Editar nativo. Abrir os ajustes fecha o painel.
- Com o painel aberto: `M` alterna o mute (item de menu oculto com atalho sem modificador, e o mesmo tratamento em `performKeyEquivalent`, para não depender do tracking), `Esc` fecha, ⌘, abre os ajustes.
- Um campo de frequência mantém o texto digitado como está, inclusive vazio ou parcial ("-" ou "1,"): não há formatter validando a cada tecla. Selecionar tudo ao entrar em edição permite substituir o valor. Return ou Tab confirmam, perder o foco confirma, Esc cancela: no commit o texto é lido com o separador decimal do locale (vírgula ou ponto), limitado e quantizado pelo `AppModel`, e o campo mostra o valor formatado. Texto vazio ou inválido volta ao valor atual sem mudar nada.
- VoiceOver:
  - sliders com `accessibilityLabel` ("Ganho", "Graves, ganho"…) e `accessibilityValue` em dB e percentual;
  - medidores com papel de indicador de nível e valor em dBFS;
  - estados ("Limitador ativo", divergência) anunciados como valor ou dica, não só como cor;
  - cada linha de microfone é um elemento de menu com o nome como rótulo, marcada como selecionada e com o valor "Selecionado" quando é a fonte atual.
- Contraste e cores: só cores semânticas do sistema (`.labelColor`, `.secondaryLabelColor`, `.controlAccentColor`).
- Aparência clara e escura e "Aumentar contraste" seguem o sistema automaticamente.

## Primeira execução

1. Pedir a permissão de microfone (`AVCaptureDevice.requestAccess(for: .audio)`), com texto de `NSMicrophoneUsageDescription`: "O MicBoost captura o microfone escolhido para amplificá-lo e entregá-lo aos seus apps."
2. Se faltar o BlackHole, mostrar a mensagem correspondente.
3. Abrir o painel automaticamente uma vez, para o usuário ver onde o app fica.

## Renderização e verificação

`MicBoostUI` contém o modelo, o menu e a janela de ajustes compartilhados com o executável auxiliar `render-screenshots`, fora do produto do app.

O painel é um menu de verdade, então a imagem que importa é a que o WindowServer compõe. `scripts/render-screenshots.sh` monta o auxiliar num bundle próprio e, para cada variante (`panel`, `eq`, `error`) e cada aparência:

1. fixa a aparência do app (`NSApp.appearance`);
2. cria o `PanelMenuController` com estado de exemplo e abre o mesmo `NSMenu` que o app usa;
3. captura as janelas do próprio processo com `SCScreenshotManager` (ScreenCaptureKit) enquanto o menu está aberto, e recorta a view de conteúdo do menu — a janela do menu inclui a sombra;
4. fecha o menu.

A janela de ajustes continua renderizada fora da tela com `NSHostingView.cacheDisplay`, porque não há menu a compor e os controles SwiftUI são AppKit por baixo. `ImageRenderer` não rasteriza controles AppKit.

O menu real é capturado como o sistema o desenha, incluindo material, cantos, títulos, marcações e atalhos. Antes da captura o auxiliar solta o foco de qualquer campo do menu (`makeFirstResponder(nil)`), para nenhum campo aparecer com anel de foco e texto selecionado. O auxiliar roda dentro do laço do app, com janela key e app ativo, para que os controles nativos (switch, sliders) sejam desenhados no estado ativo; a captura acontece a partir do laço de tracking do menu, que é o único momento em que a janela existe. O executável do auxiliar fixa o locale a partir do idioma resolvido pelo catálogo (`UILanguage.locale`: en → `en_US`, pt-BR → `pt_BR`), para que os números das capturas acompanhem o texto; as views AppKit formatam números com `AppModel.formatLocale`, que o auxiliar fixa no mesmo locale.

O app consulta snapshots de estado a 1 Hz; os medidores têm tarefa separada de 20 Hz, cancelada ao fechar o painel. A expansão do EQ fica em `UserDefaults.eqExpanded`. A validação manual de VoiceOver, contraste e preferências de acessibilidade está pendente.

O executável do app e o auxiliar de capturas registram o SDK real de compilação separadamente do mínimo macOS 14. O AppKit assim escolhe os controles da geração atual do sistema; não aplicar transformações de escala nem desenhar uma versão própria dos controles.

O menu ativa o app ao abrir para que os controles AppKit sejam apresentados ativos.
