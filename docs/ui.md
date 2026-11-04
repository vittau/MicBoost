# Interface

## Princípios

- Terminologia: a UI chama a entrada processada de "MicBoost". O nome "BlackHole 2ch" só aparece onde o usuário precisa reconhecê-lo: ao escolher o microfone dentro de um app que não segue a entrada do sistema, e quando o driver está ausente.

- A aparência e o comportamento nativos são a diretriz para toda a interface: preferir componentes AppKit/SwiftUI, métricas e cores do sistema; personalizar apenas o necessário para o painel. Ações de menu ficam em texto, switches usam o estilo do sistema e campos mantêm os comandos padrão de edição.
- Parecer parte do sistema: materiais, tipografia (fonte do sistema, tamanhos de controle `.regular`/`.small`), espaçamento e cantos dos módulos de Som/Bluetooth da Central de Controle; ícones SF Symbols; sliders, toggles e listas nativos.
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

`NSMenu` padrão do AppKit, sem seta, com `PanelView` hospedada na `view` de um `NSMenuItem`:
- moldura, material, transparência, sombra e cantos desenhados pelo próprio menu, sem camadas de fundo adicionais;
- conteúdo SwiftUI de 320 pt, com padding de conteúdo e sem herdar safe areas da janela interna do menu; mudanças de tamanho atualizam o frame da view do item;
- aberto sob o `NSStatusBarButton`, alinhado à direita e limitado à tela pelo AppKit;
- fechamento e navegação do menu gerenciados pelo AppKit, inclusive Escape e clique fora;
- o delegate inicia os medidores ao abrir e os cancela ao fechar;
- entrada no tracking pelo run loop para não manter um job de concorrência Swift ocupado.

**Fechar o painel nunca afeta o motor.** Aparência e preferências de acessibilidade
são herdadas do sistema. Não alterar o fundo, recorte ou opacidade da janela do menu.

Conteúdo, de cima para baixo (SwiftUI, `PanelView`):

1. **Cabeçalho:** no mesmo layout do topo dos menus de Wi-Fi e Bluetooth do macOS: título "MicBoost" em negrito à esquerda e um `Toggle` com `.toggleStyle(.switch)` alinhado à direita, controlando o processamento (`processingEnabled`). Fica sempre visível no topo e alcançável com um clique ao abrir o painel. É o jeito principal de parar o MicBoost e **soltar o microfone**:
   - **Desligar:** para o motor por completo (rampa, `AudioDeviceStop`, IOProc e agregado destruídos), de modo que o microfone deixa de ser capturado e o indicador de microfone do macOS apaga. A entrada padrão é restaurada conforme a [política](audio-engine.md#política-de-entrada-padrão-defaultinputmanager), e o ícone vira `mic`.
   - **Ligar:** reconstrói o motor com a fonte e os ajustes persistidos e reaplica a política de entrada padrão.
   - O estado persiste (`processingEnabled`), e a troca nunca fecha o painel.
2. **Ganho:** botão de mute com o ícone `mic.fill`/`mic.slash.fill` centralizado em uma área fixa de 20 × 20 pt para não deslocar o slider ao alternar, `Slider` de ganho de −12 a +24 dB e rótulo `398% (+12,0dB)` (percentual primeiro; dB entre parênteses). O valor é editável: clicar no rótulo abre um campo numérico em dB. O selo "Limitador ativo" (pílula discreta) aparece ao lado do valor de ganho durante a proteção de pico; sua área permanece reservada e o selo fica oculto para acessibilidade quando inativo, sem alterar a altura do painel ou deslocar controles.
3. **Medidores:** duas barras horizontais de 6 pt de espessura (como a trilha do slider de ganho), "Entrada" e "Saída", com comprimento proporcional à amplitude de pico (0…1), valores de acessibilidade em dBFS de −60 a 0, sempre na cor de destaque do sistema, sem flash vermelho nem aviso textual de saturação.
4. **Entrada do sistema:** apenas o estado da entrada padrão; a fonte selecionada é indicada pela marcação na lista de microfones, sem uma linha adicional de caminho do áudio:
   - ok: "Entrada do sistema: MicBoost" com marcação;
   - divergência: "Entrada do sistema: <nome>" + botão "Usar MicBoost".
   - com `manageDefaultInput` desligado, a linha só informa a entrada atual, sem tratá-la como divergência; o botão "Usar MicBoost" aparece se a entrada não for o BlackHole.
5. **Microfone:** lista de fontes elegíveis no estilo das listas de dispositivos da Central de Controle (ícone por transporte, nome, marca de seleção). Selecionar troca a fonte (reconstrução do motor com rampa). Uma fonte persistida que não está conectada aparece como "<nome> (desconectado)".
6. **Equalizador:** seção expansível (`DisclosureGroup`, recolhida por padrão; o estado de expansão persiste; clicar no título ou no chevron alterna a expansão, e o teclado continua usando o controle nativo), com switch nativo "Ativar EQ" sempre visível à direita do título, independente da expansão. Alternar o switch não expande nem recolhe os ajustes. A expansão muda a altura em uma única atualização, sem animação SwiftUI concorrendo com o redimensionamento do menu AppKit. Apenas as bandas e ações ficam na área recolhível:

   - Graves: slider de ganho (dB) + campo de frequência (Hz);
   - Médios: slider de ganho + campo de frequência + slider "Largura" com o valor de Q mostrado (Q maior = banda mais estreita);
   - Agudos: slider de ganho + campo de frequência;
   - ações sem borda "Padrão de voz" e "Zerar EQ" na mesma linha.

   Cada banda é um bloco separado por espaçamento e divisor, com título em `.headline`
   negrito (como "Microfone") e marcação de cabeçalho para acessibilidade. O controle
   de largura fica dentro do bloco de Médios. O ganho de cada banda aparece numericamente junto ao título; campos de frequência têm largura compacta e alinhamento numérico à direita.

   Valores editáveis, validados e limitados às faixas de [dsp.md](dsp.md#equalizador). Sem gráfico de resposta.
7. **Rodapé:** opções de menu em texto puro, uma por linha e alinhadas à esquerda, "Ajustes…" (abre a janela de ajustes) e "Sair do MicBoost". Sem moldura de botão; a linha inteira é clicável e ganha destaque semântico ao passar o ponteiro ou pressionar, como as ações nos painéis de Som do macOS.

### Mensagens de estado

Uma faixa no topo do conteúdo, abaixo do cabeçalho, mostra uma mensagem por vez, na ordem de prioridade:

| Estado | Mensagem | Ação |
|---|---|---|
| `microphonePermissionDenied` | "O MicBoost não tem acesso ao microfone." | "Abrir Ajustes de Privacidade" → `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| `blackHoleMissing` | "BlackHole 2ch não encontrado." | "Como instalar" (abre a documentação de instalação) |
| `sourceUnavailable` / `recovering(.sourceLost)` | "<nome> desconectado. O áudio volta quando ele for reconectado." | escolher outro microfone na lista |
| `formatUnsupported` | "Formato do <nome> não suportado." | escolher outro microfone |
| `halFailure` | "Falha no áudio do sistema." | "Tentar novamente" |
| divergência da entrada padrão | (na linha de roteamento) | "Usar MicBoost" |

### Medidores na UI

`NSControl` com papel de acessibilidade de indicador de nível, somente de leitura, apresenta os valores sem interpolação de
progresso. Seu desenho usa apenas a trilha nativa de `NSSliderCell.drawBar`, sem knob,
na altura de 6 pt; o AppKit define a curvatura e a cor de destaque em toda a faixa. `MeterPoller` (main actor) lê `mb_engine_read_meters` por meio do controller a 20 Hz, só enquanto o painel está visível, e aplica decaimento visual de 20 dB/s calculado a cada leitura. Subidas usam o pico da leitura seguinte; apenas a queda é gradual (30 dB levam 1,5 s). Essa duração visual é independente da latência do áudio. Com "Reduzir movimento", não há interpolação: cada leitura é exibida diretamente.

## Janela de ajustes

`NSWindow` de 540 pt de largura com SwiftUI `SettingsView` (`Form` com estilo `.grouped`), aberta por "Ajustes…" ou ⌘, com o painel focado. Seções:

As seções seguem o estilo dos Ajustes do Sistema: cartões agrupados nativos,
controles com tamanho padrão do sistema, switch nativo à direita com explicação secundária
junto ao rótulo e linhas de diagnóstico/sobre com rótulo à esquerda e valor à direita.

- **Áudio:** chave "Usar MicBoost como entrada do sistema automaticamente" (`manageDefaultInput`, ligada por padrão), com uma frase explicando que, desligada, cada app precisa selecionar o microfone "BlackHole 2ch" por conta própria; "Buffer (quadros)" (64/128/256/512/1024, só os valores suportados), com descrição abaixo explicando que valores menores reduzem o atraso e valores maiores podem evitar cortes ou estalos; manter o padrão se o áudio estiver estável e modo de canais da fonte atual ([audio-engine.md](audio-engine.md#canais)), com uma linha de legenda para cada opção disponível: Mono 1 (padrão), Mono 2 e demais canais mono em ordem crescente, Misturar e Estéreo. Mono N usa o canal N nos dois lados; Misturar combina todos; Estéreo separa os canais 1 e 2 em esquerda e direita. A lista e as legendas seguem essa ordem; Estéreo só aparece com dois ou mais canais.
- **Diagnóstico** (somente leitura, atualização a 1 Hz com a janela visível): taxa de amostragem, buffer, latência reportada, overloads, `input_missing`, `nonfinite_resets`. Botão "Copiar relatório" (texto para a área de transferência).
- **Sobre:** versão, link do projeto e informação de licença.

## Teclado e acessibilidade

- Todo controle é alcançável por Tab, e as setas ajustam sliders: ganho em passos de 0,5 dB (1 dB com ⌥); EQ em 0,5 dB, frequência em 1/12 de oitava.
- ⌘Q encerra o app e ⌘, abre os ajustes; campos de texto usam Recortar/Copiar/Colar/Selecionar Tudo do menu Editar nativo. Abrir os ajustes fecha o painel.
- Atalhos com o painel focado: `M` alterna o mute, `Esc` fecha, ⌘, abre os ajustes.
- VoiceOver:
  - sliders com `accessibilityLabel` ("Ganho", "Graves, ganho"…) e `accessibilityValue` em dB e percentual;
  - estados ("Limitador ativo", divergência) anunciados como valor ou dica, não só como cor;
  - lista de microfones com estado "selecionado".
- Contraste e cores: só cores semânticas do sistema (`.primary`, `.secondary`, `.tint`).
- Aparência clara e escura e "Aumentar contraste" seguem o sistema automaticamente.

## Primeira execução

1. Pedir a permissão de microfone (`AVCaptureDevice.requestAccess(for: .audio)`), com texto de `NSMicrophoneUsageDescription`: "O MicBoost captura o microfone escolhido para amplificá-lo e entregá-lo aos seus apps."
2. Se faltar o BlackHole, mostrar a mensagem correspondente.
3. Abrir o painel automaticamente uma vez, para o usuário ver onde o app fica.

## Renderização e verificação

`MicBoostUI` contém o modelo e as views compartilhadas com o executável auxiliar
`render-screenshots`, fora do produto do app. `scripts/render-screenshots.sh` usa
`NSHostingView.cacheDisplay` numa janela fora da tela para incluir controles AppKit
nativos, em ambas as aparências; `ImageRenderer` não rasteriza esses controles.
O app consulta snapshots de estado a 1 Hz; os medidores têm tarefa separada de 20 Hz,
cancelada ao fechar o painel. A expansão do EQ fica em `UserDefaults.eqExpanded`.
A validação manual de VoiceOver, contraste e preferências de acessibilidade está pendente.

As capturas fora da tela documentam o conteúdo SwiftUI, não a composição do menu
com o desktop. Moldura e transparência exigem conferir o menu real composto pelo
WindowServer.

O executável do app e o auxiliar de capturas registram o SDK real de compilação
separadamente do mínimo macOS 14. O AppKit assim escolhe os controles da geração
atual do sistema, incluindo o switch nativo de 54 × 24 pt no macOS 27; não aplicar
transformações de escala nem desenhar uma versão própria desse controle.

O menu ativa o app ao abrir para que os controles AppKit sejam apresentados ativos.
Os toggles usam `.toggleStyle(.switch)`, sem tamanho, escala, tint ou estado visual
forçados: o AppKit escolhe as métricas e a cor de destaque a partir do sistema.

Os medidores usam amplitude linear: comprimento = `10^(dBFS/20)`, limitado a 0…1;
valores de −60 dBFS ou menores ficam em zero. 0 dBFS preenche 100% da barra.
Com EQ plano e sem redução do limitador, ganho de 200% produz uma barra de saída
duas vezes maior que a de entrada. As barras representam os picos reais antes
do EQ e depois do limitador, e não uma projeção do ganho escolhido.
O teto de −1 dBFS corresponde a 89,13% da barra; o áudio mantém esse teto.
