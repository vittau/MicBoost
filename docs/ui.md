# Interface

## Princípios

- Parecer parte do sistema: materiais, tipografia (fonte do sistema, tamanhos de controle `.regular`/`.small`), espaçamento e cantos dos módulos de Som/Bluetooth da Central de Controle; ícones SF Symbols; sliders, toggles e listas nativos.
- Sem aparência de mixer de estúdio e sem animações contínuas. Os medidores são o único elemento atualizado periodicamente, e só com o painel visível.
- Toda a UI vem do `AppModel` (`@Observable`, `@MainActor`), que reflete o `EngineStatus` e encaminha comandos ao `EngineController`. A UI nunca chama a HAL.
- Idiomas: pt-BR e en, via String Catalog (`Localizable.xcstrings`) nos recursos do target `MicBoostApp`, usando `String(localized:)`/`LocalizedStringKey`. Idioma de desenvolvimento: en.

## Item da barra de menus

- `NSStatusItem` com SF Symbol template:
  - `mic.fill`: rodando;
  - `mic.slash.fill`: mudo;
  - `mic`: processamento desligado;
  - `exclamationmark.triangle.fill`: erro ou divergência da entrada padrão.
- Clique (esquerdo ou direito) abre e fecha o painel. O rótulo de acessibilidade descreve o estado (por exemplo, "MicBoost, ativo, +12 dB").

## Painel

`MenuBarPanel`: subclasse de `NSPanel` com:
- estilo `.nonactivatingPanel` + `.borderless`;
- `canBecomeKey = true`, para foco de teclado;
- conteúdo em `NSVisualEffectView` (`material: .popover`, `state: .active`, cantos arredondados de 12 pt);
- largura fixa de 320 pt e altura que segue o conteúdo;
- ancorado abaixo do item de status, alinhado à borda direita do botão e mantido dentro da tela visível.

Fecha com clique fora (monitor global de mouse), `Esc` ou novo clique no ícone. **Fechar o painel nunca afeta o motor.** Com "Reduzir transparência" ativo, o sistema troca o material por uma cor sólida (comportamento nativo do `NSVisualEffectView`); não desativar.

Conteúdo, de cima para baixo (SwiftUI, `PanelView`):

1. **Cabeçalho:** "MicBoost" + `Toggle` estilo switch para o processamento (`processingEnabled`).
2. **Ganho:** botão de mute com o ícone `mic.fill`/`mic.slash.fill`, `Slider` de ganho de −12 a +24 dB e rótulo `+12,0 dB · 398%`. O valor é editável: clicar no rótulo abre um campo numérico em dB. O selo "Limitando" (pílula discreta) aparece durante a proteção de pico.
3. **Medidores:** duas barras finas horizontais, "Entrada" e "Saída", em dBFS de −60 a 0, que só mudam de cor perto de 0. Aviso "Entrada saturada" quando `input_clipped`.
4. **Roteamento:** linha "Microfone → BlackHole 2ch" e estado da entrada padrão:
   - ok: "Entrada do sistema: BlackHole 2ch" com marcação;
   - divergência: "Entrada do sistema: <nome>" + botão "Usar BlackHole".
5. **Microfone:** lista de fontes elegíveis no estilo das listas de dispositivos da Central de Controle (ícone por transporte, nome, marca de seleção). Selecionar troca a fonte (reconstrução do motor com rampa). Uma fonte persistida que não está conectada aparece como "<nome> (desconectado)".
6. **Equalizador:** seção expansível (`DisclosureGroup`, recolhida por padrão; o estado de expansão persiste), com:
   - `Toggle` "Ativar EQ";
   - Graves: slider de ganho (dB) + campo de frequência (Hz);
   - Médios: slider de ganho + campo de frequência + slider "Largura" com o valor de Q mostrado (Q maior = banda mais estreita);
   - Agudos: slider de ganho + campo de frequência;
   - botão "Zerar EQ".

   Valores editáveis, validados e limitados às faixas de [dsp.md](dsp.md#equalizador). Sem gráfico de resposta.
7. **Rodapé:** "Ajustes…" (abre a janela de ajustes) e "Sair do MicBoost".

### Mensagens de estado

Uma faixa no topo do conteúdo, abaixo do cabeçalho, mostra uma mensagem por vez, na ordem de prioridade:

| Estado | Mensagem | Ação |
|---|---|---|
| `microphonePermissionDenied` | "O MicBoost não tem acesso ao microfone." | "Abrir Ajustes de Privacidade" → `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| `blackHoleMissing` | "BlackHole 2ch não encontrado." | "Como instalar" (abre a documentação de instalação) |
| `sourceUnavailable` / `recovering(.sourceLost)` | "<nome> desconectado. O áudio volta quando ele for reconectado." | escolher outro microfone na lista |
| `formatUnsupported` | "Formato do <nome> não suportado." | escolher outro microfone |
| `halFailure` | "Falha no áudio do sistema." | "Tentar novamente" |
| divergência da entrada padrão | (na linha de roteamento) | "Usar BlackHole" |

### Medidores na UI

`MeterPoller` (main actor) lê `mb_engine_read_meters` por meio do controller a 20 Hz, só enquanto o painel está visível, e aplica decaimento visual de 20 dB/s calculado a cada leitura. Com "Reduzir movimento", não há interpolação: cada leitura é exibida diretamente.

## Janela de ajustes

`NSWindow` com SwiftUI `SettingsView` (`Form` com estilo `.grouped`), aberta por "Ajustes…" ou ⌘, com o painel focado. Seções:

- **Áudio:** tamanho de buffer (128/256/512/1024, só os valores suportados) e modo de canais da fonte atual ([audio-engine.md](audio-engine.md#canais)).
- **Diagnóstico** (somente leitura, atualização a 1 Hz com a janela visível): taxa de amostragem, buffer, latência reportada, overloads, `input_missing`, `nonfinite_resets`. Botão "Copiar relatório" (texto para a área de transferência).
- **Sobre:** versão, link do projeto, aviso de que o app não é notarizado e informação de licença.

## Teclado e acessibilidade

- Todo controle é alcançável por Tab, e as setas ajustam sliders: ganho em passos de 0,5 dB (1 dB com ⌥); EQ em 0,5 dB, frequência em 1/12 de oitava.
- Atalhos com o painel focado: `M` alterna o mute, `Esc` fecha, ⌘, abre os ajustes.
- VoiceOver:
  - sliders com `accessibilityLabel` ("Ganho", "Graves, ganho"…) e `accessibilityValue` em dB e percentual;
  - estados ("Limitando", "Entrada saturada", divergência) anunciados como valor ou dica, não só como cor;
  - lista de microfones com estado "selecionado".
- Contraste e cores: só cores semânticas do sistema (`.primary`, `.secondary`, `.tint`, `.red` para clipping).
- Aparência clara e escura e "Aumentar contraste" seguem o sistema automaticamente.

## Primeira execução

1. Pedir a permissão de microfone (`AVCaptureDevice.requestAccess(for: .audio)`), com texto de `NSMicrophoneUsageDescription`: "O MicBoost captura o microfone escolhido para amplificá-lo e enviá-lo ao BlackHole."
2. Se faltar o BlackHole, mostrar a mensagem correspondente.
3. Abrir o painel automaticamente uma vez, para o usuário ver onde o app fica.
