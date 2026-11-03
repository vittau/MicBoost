# Testes e medição

## Testes automatizados (`swift test`)

Rodam sem hardware de áudio, sem BlackHole e sem permissão de microfone. Usam o Swift Testing (`import Testing`). A suíte completa leva no máximo 1 minuto em média na máquina de referência, sem contar a compilação. Sinais de teste usam a menor duração que ainda dá precisão (por exemplo, assentamento de filtro em vez de segundos de áudio), e tempos de espera reais (debounce, coalescência) ficam curtos ou são injetados.

### `MicBoostDSPTests` (processador via `mb_engine_process`)

Em 16, 44,1, 48 e 96 kHz:

- **Resposta plana:** todas as bandas a 0 dB com EQ ligado → saída idêntica à entrada (ruído branco, erro ≤ 1e−6), com ganho de 0 dB e o limitador inativo (sinal ≤ −6 dBFS).
- **Resposta das bandas:** senoides de teste depois do assentamento, comparadas com a magnitude teórica da RBJ (tolerância ±0,1 dB):
  - low shelf +12 dB a 120 Hz: ganho em 20 Hz ≈ +12 dB e em 2 kHz ≈ 0 dB;
  - peaking +12 dB a 1 kHz: +12 dB no centro;
  - high shelf: espelho do low shelf;
  - mesmos casos com −12 dB.
- **Limites de frequência:** frequências acima de 0,45·fs são limitadas e o filtro permanece estável (saída finita e limitada com um impulso).
- **Bypass:** EQ com +12 dB em todas as bandas e bypass ligado → depois de 20 ms, saída = entrada.
- **Ganho:** degrau de 0 para +12 dB atinge 99% do alvo em ≈ 5τ e não tem descontinuidade (|Δy| entre amostras consecutivas ≤ limite derivado do sinal).
- **Mute e fade-out:** a saída converge a zero e `fade_done` é sinalizado.
- **Limitador:** senoide de 0 dBFS + ganho +24 dB + EQ +12 dB → max|y| ≤ 0,891 + 1e−6. O GR reportado é coerente.
- **Sem cliques:** alterações abruptas de frequência, ganho e Q durante uma senoide não produzem saltos acima do limite.
- **Robustez:** entrada com NaN/Inf → saída finita, `nonfinite_resets` incrementado.
- **Blocos grandes:** `frames > max_frames` é processado em blocos sem estourar memória.
- **Sem alocação:** `mb_engine_process` é verificado por revisão. Opcionalmente, com um `malloc` interposto no teste, contar chamadas durante o processo, que devem ser 0.

### `MicBoostCoreTests` (com `FakeAudioHardware`)

- Política de entrada padrão: todos os casos de [audio-engine.md](audio-engine.md#política-de-entrada-padrão-defaultinputmanager), incluindo crash simulado (`defaultInputManaged` persistido), divergência do usuário, dispositivo anterior ausente e BlackHole já padrão.
- Nunca chama a escrita da saída padrão. A fake falha o teste se isso acontecer.
- Elegibilidade de fontes: exclui as variantes de BlackHole, o próprio agregado e agregados com BlackHole.
- Máquina de estados: transições de [architecture.md](architecture.md#ciclo-de-vida-do-motor) para cada evento de recuperação.
- Mapa de canais: fontes com 1, 2 e 8 canais, streams intercalados e não intercalados, fonte com saídas próprias.
- Settings: valores padrão, round-trip (incluindo todas as `ChannelSelection`), esquema desconhecido e dados corrompidos → padrões, campos ausentes mantendo o padrão, valores fora de faixa limitados, debounce de 300 ms coalescendo várias mudanças numa gravação e gravação imediata dos campos de entrada padrão.

## Ferramenta de diagnóstico (`micboost-diag`)

CLI para verificar o hardware. `run` e `latency` aceitam `--gain-db N`, `--mute`, `--eq-low F:G`, `--eq-mid F:G:Q`, `--eq-high F:G` e `--eq-off`; os valores são validados e limitados às faixas de settings. Os controles de diagnóstico ficam em domínio de preferências separado do app. `run` publica pico de entrada, pico de saída, GR e CPU acumulada a cada segundo. `run`, `latency` e `soak` não alteram as entradas ou saídas padrão; a política de entrada padrão ainda não está integrada a esses comandos. `latency` aceita `--buffer`; `soak` aceita `--buffer` e usa 20 minutos quando `--minutes` não é informado. A opção `permission` imprime o estado de autorização do microfone sem solicitar acesso.

É o meio pelo qual agentes sem acesso a áudio verificam o comportamento real. Pela regra de TCC, quem precisa de permissão de microfone é o app de terminal que a executa (Terminal, Orca etc.).

| Comando | Função |
|---|---|
| `micboost-diag devices [--json]` | Lista dispositivos com UID, transporte, canais, taxas, faixa de buffer, latências, safety offsets e elegibilidade; mostra o BlackHole detectado e a entrada padrão |
| `micboost-diag run --input <uid> [--buffer N] [--seconds N]` | Roda o motor sem UI (mesmo `EngineController` do app), imprimindo estado e contadores a cada segundo. Não altera a entrada ou saída padrão; integração com a política de entrada padrão fica para o app |
| `micboost-diag capture --device <uid> --seconds N --out file.wav` | Grava a entrada bruta de um dispositivo |
| `micboost-diag latency --input <uid> [--trials N]` | Mede a latência adicional (método abaixo) |
| `micboost-diag soak --input <uid> [--minutes N]` (padrão 20) | Ensaio de estabilidade (abaixo) |

A CLI usa parsing manual, sem dependências externas. `devices` exibe transporte por nome, taxas como lista simples em Hz (intervalos quando aplicável), latências e safety offsets em frames e milissegundos na taxa nominal. O JSON preserva os valores numéricos do `DeviceSnapshot` (`devices` e `defaultInputUID`); elegibilidade e BlackHole são derivados dos campos.

`capture` aceita duração positiva de até 300 segundos e grava WAV IEEE Float32 intercalado na taxa nominal. Imprime frames efetivamente capturados, pico e RMS lineares por canal. A duração inclui a partida do dispositivo; Continuity pode entregar menos frames durante a conexão. A extensão de `CoreAudioHardware` valida os formatos virtuais Float32 nativos sem modificar formatos ou padrões, cria um IOProc C e pré-aloca o buffer em `mb_capture_create`. O callback apenas copia amostras; gravação WAV e cálculo de pico/RMS acontecem após stop e destruição do IOProc. Outros formatos são recusados sem alterar o hardware. Capturas locais ficam em `.scratch/` e não entram no git.

## Medição de latência

**Fronteira medida:** da amostra disponível na fonte até a mesma amostra disponível para um leitor do BlackHole. Esse é o atraso acrescentado pelo MicBoost em relação a um app que lesse o microfone diretamente. O atraso dos apps consumidores (Zoom, gravadores) é medido à parte, quando relevante, e não entra nessa conta.

Método (`micboost-diag latency`):
1. O motor roda no próprio processo da ferramenta (fonte → BlackHole, ganho 0 dB, EQ desligado).
2. Dois IOProcs auxiliares de captura, um direto na fonte e outro na entrada do BlackHole, gravam com o `mHostTime` do início de cada buffer em buffers pré-alocados.
3. A implementação usa o sinal da sala, sem emitir sons. Um clique (impulso de 1 ms) é tocado na saída padrão (`afplay` ou um IOProc de saída). Em alternativa, o usuário estala os dedos perto do microfone.
4. A ferramenta captura dois segundos por tentativa, usa o host time do primeiro buffer para alinhamento, busca correlação normalizada em ±100 ms e exige correlação ≥ 0,5; sem sinal suficiente, falha explicitamente. A ferramenta alinha as duas gravações pelo host time, calcula a correlação cruzada e obtém o atraso. Repete N vezes (padrão 10) e reporta mediana, mínimo e máximo, em ms e em frames.
5. Também imprime a latência reportada pela HAL e `io_delta_host`, para comparar.

**Aceitação (v1, fonte → BlackHole):** mediana ≤ 100 ms em toda fonte suportada, exceto fontes cuja própria latência de entrada reportada já exceda esse valor (por exemplo, Continuity), que ficam documentadas como limitação.

**Objetivo de engenharia:** mediana < 20 ms no buffer padrão para fontes USB e internas a 48 kHz. É o requisito do modo monitor da v2, então desvios são registrados abaixo com a causa.

## Ensaio de estabilidade (20 min)

`micboost-diag soak`:
- roda o motor com a fonte real;
- a cada 60 s, mede a latência pelo método acima, com o clique ou com o próprio sinal da sala por correlação;
- registra overloads, `input_missing`, `nonfinite_resets`, CPU (`task_info`) e memória residente.

Aprovação:
- deriva de latência entre o primeiro e o último minuto < 1 ms;
- 0 overloads;
- 0 `nonfinite_resets`;
- memória estável (±1 MB).

Complementar com uma escuta humana de uma gravação de voz de 20 min via BlackHole, procurando cortes e estalos.

## Roteiro manual (antes de cada release)

1. Instalação limpa (Homebrew e `.zip`) em um Mac sem BlackHole e em um Mac com BlackHole já instalado ([distribution.md](distribution.md)).
2. Primeira abertura: permissão de microfone, mensagem sem BlackHole, painel abrindo automaticamente.
3. Microfone interno e um USB ou interface: voz amplificada em um app de chamada (FaceTime ou Zoom) e em um gravador (QuickTime ou Voice Memos), com o app em "padrão do sistema" e em "BlackHole 2ch".
4. Ganho acima de +6 dB com "Limitando" visível ao gritar; mute; EQ nos extremos; bypass; "Zerar EQ"; nenhum clique perceptível ao mexer nos controles com voz.
5. Fechar e abrir o painel durante uma chamada: o áudio não é interrompido.
6. Desconectar e reconectar o USB; suspender e retomar; mudar a taxa da fonte no Configuração de Áudio e MIDI; mudar a entrada padrão manualmente e usar "Usar BlackHole".
7. Sair do app: a entrada anterior é restaurada (e não é restaurada se o usuário tiver mudado manualmente).
8. Bluetooth (AirPods ou similar): registrar taxa, latência medida e degradação da saída do fone.
9. VoiceOver, navegação por teclado, aparência clara/escura, Reduzir transparência e Reduzir movimento.
10. Persistência: reabrir o app e conferir ganho, mute, EQ, fonte e canais.

## Resultados registrados


Validação de ganho e EQ (2026-11-03): C920 USB, 16 kHz, buffer 256, canal automático (primeiro canal copiado para L/R). Capturas simultâneas da fonte e do BlackHole de 3 s após 2 s de assentamento, usando o sinal ambiente; picos variam com o alinhamento e com o resampler de drift.

| Ganho | Fonte pico / RMS (canal 1) | BlackHole pico / RMS (L = R) | Razão RMS |
|---|---|---|---|
| 0 dB | 0,21924 / 0,012676 | 0,22361 / 0,012660 | 0,999 |
| +6 dB | 0,23941 / 0,015418 | 0,54723 / 0,031360 | 2,034 |
| +12 dB | 0,05301 / 0,006345 | 0,20991 / 0,025283 | 3,984 |
| +24 dB | 0,01721 / 0,004814 | 0,27370 / 0,075962 | 15,779 |

- Limitador em hardware: 60 s com +24 dB e médios +12 dB / 1 kHz / Q 0,9; pico máximo de saída 0,891; GR máximo 1,448 dB. Zero overloads, entradas ausentes e resets não finitos.
- CPU nesse ensaio: 0,462 s em 59 s entre leituras (0,78% de um núcleo); CPU total até a última leitura 0,510 s. EQ habilitado, shelves em 0 dB.
- Latência, 3 tentativas: EQ em bypass mediana/mín./máx. 38,875 / 38,875 / 38,9375 ms; médios ativos +6 dB / 1 kHz / Q 0,9: 38,875 / 38,8125 / 38,875 ms. Mediana 622 frames em ambos, diferença 0 frames; correlação ≥ 0,965 com EQ.
- Finalização: BlackHole 48.000 Hz, entrada padrão `BuiltInMicrophoneDevice` preservada, nenhum processo `micboost-diag` restante. Nenhuma captura de Continuity ou Bluetooth.
- A faixa permanece −12…+24 dB. Calibração com voz humana e escuta para estalos são verificações manuais pendentes; o ensaio usou som ambiente e os testes offline verificam transições numericamente.
- Testes automatizados: 11 testes DSP em 0,135 s e 37 Core em 1,523 s (1,658 s somados, sem compilação) (48 funções, com os casos DSP parametrizados nas quatro taxas); o único problema conhecido é a escrita proibida proposital na HAL falsa, já esperado pelo teste. `swift build`, `swift test` e `swift format lint --recursive Sources Tests` aprovados.
- Revisão de tempo real: processamento C sem alocação, locks, logs, HAL ou chamadas Swift/Objective-C; memória temporária pré-alocada, coeficientes apenas quando parâmetros se movem, estados denormais zerados ao fim dos sub-blocos.

Máquina de referência: MacBook Neo (Apple A18 Pro), macOS 27.2. Latências medidas por correlação com o som da sala, 3 tentativas cada (mediana/mín./máx.).

| Medida | Condição | Resultado |
|---|---|---|
| Latência adicional | microfone interno, 48 kHz, buffer 256 | — |
| Latência adicional | microfone interno, 48 kHz, buffer 128 | — |
| Latência adicional | USB (fifine), 48 kHz, buffer 256 | 15,31 / 15,29 / 15,31 ms; HAL 11,5 ms (2026-11-03) |
| Latência adicional | USB (fifine), 48 kHz, buffer 128 | 9,96 / 9,94 / 9,96 ms; HAL 8,8 ms (2026-11-03) |
| Latência adicional | USB (fifine), 48 kHz, buffer 64 | 7,29 / 7,29 / 7,29 ms; HAL 7,5 ms (2026-11-03) |
| Latência adicional | USB (C920), 16 kHz, buffer 64 | 14,94 / 14,88 / 14,94 ms; HAL 10,5 ms (2026-11-03) |
| Latência adicional | USB (C920), 16 kHz, buffer 128 | 22,88 / 22,88 / 22,88 ms; HAL 14,5 ms (2026-11-03) |
| Latência adicional | USB (C920), 16 kHz, buffer 256 | 38,94 / 38,88 / 38,94 ms; HAL 22,5 ms (2026-11-03) |
| Latência adicional | Bluetooth | — |
| Passagem fonte → BlackHole | C920, 16 kHz, `run` + capturas simultâneas | fonte pico/RMS 0,0654 / 0,0056; BlackHole L = R 0,0630 / 0,0057 (2026-11-03) |
| Silêncio seguro | fonte que entrega zeros (microfone interno com a tampa fechada) | BlackHole pico/RMS 0 nos dois canais (2026-11-03) |
| Ensaio de estabilidade | C920, 16 kHz, buffer 256, 18 min | deriva −0,06 ms (38,88 → 38,81 ms); 0 overloads, `input_missing` e `nonfinite_resets`; CPU ≈ 0,4% de um núcleo; memória só como pico (maxRSS constante 15,6 MB) (2026-11-03) |
| Ensaio de estabilidade | C920, 16 kHz, buffer 256, 20 min, RSS instantânea | deriva −0,69 ms (38,88 → 38,19 ms; estável até o minuto 8, depois queda de ≈ 0,06 ms/min); 0 overloads, `input_missing` e `nonfinite_resets`; RSS 12,9–13,6 MB após o minuto 3; CPU 5,9 s (≈ 0,5% de um núcleo) (2026-11-03) |
| Recuperação física | fifine, 48 kHz, `run`; USB desconectado ≈ 5 s e reconectado | `running` → `recovering(sourceLost)` → `running` sem intervenção, 12 s em recuperação; contadores de erro 0 (2026-11-03) |
| CPU do processo | running, EQ ligado | — |
| Captura bruta | microfone interno, 48 kHz, 3 s | pico 0,102; RMS 0,0054 (2026-11-03) |
| Captura bruta | Continuity, 48 kHz, 3 s | pico 0,0039; RMS 0,0010 (2026-11-03) |
| Latência de entrada reportada pela HAL | Continuity, 48 kHz | 6000 frames (125 ms) |

(— = ainda não medido. Substituir pelo valor e pela data da medição.)

Observações de hardware:
- Com a tampa fechada, o macOS silencia o microfone interno por hardware: a permissão continua concedida e os callbacks entregam zeros. A medição de latência recusa esse sinal (correlação 0).
- As pequenas diferenças de nível entre fonte e BlackHole vêm do resampler de drift e de capturas que começam em instantes distintos.
- A queda lenta de latência no ensaio de 20 min passa no critério, mas não está claro se ela se estabiliza (resampler de deriva acomodando) ou continua (deriva residual). Um ensaio de várias horas antes da release decide.
- Reinício real do `coreaudiod` e escuta humana são verificações manuais. A HAL falsa cobre perda e retorno da fonte e do BlackHole.

### Interface e ciclo de vida do app

Na máquina de referência, com a C920 USB a 16 kHz e buffer 256:
- entrada padrão antes: `BuiltInMicrophoneDevice`;
- app rodando: `BlackHole2ch_UID`, confirmado por `micboost-diag devices` e pela linha de roteamento da árvore de acessibilidade;
- switch de processamento desligado pelo controle real (valor AX 0): entrada restaurada para `BuiltInMicrophoneDevice`, sem agregado MicBoost enumerado;
- saída via AppleScript apontando para o bundle construído: entrada `BuiltInMicrophoneDevice`;
- verificação final após `micboost-diag run --input BuiltInMicrophoneDevice --seconds 2`: BlackHole a 48000 Hz, entrada padrão `BuiltInMicrophoneDevice`, sem processos MicBoost ou diagnóstico iniciados pela tarefa.

O agregado é privado; sua ausência na enumeração externa é uma verificação adicional,
não prova isolada da liberação. O caminho de stop destrói IOProc e agregado, coberto
pelos testes com HAL falsa. Não houve captura de Continuity ou Bluetooth.
Capturas claras/escuras verificadas visualmente; sliders sem marcas de passo.
VoiceOver, todos os atalhos, reduzir movimento/transparência e contraste aumentado
permanecem sem validação manual completa. A etapa 4 permanece em andamento.

Verificação automatizada da interface: 54 testes (3 UI, 11 DSP, 40 Core),
execução somada de 1,72 s; a suíte Core inclui o caso negativo
`fakeRejectsOutputWrite`, que registra uma issue conhecida intencionalmente.
`swift build`, `swift test`, lint recursivo de formatação, montagem debug e
`codesign --verify --strict` passam na máquina de referência.

O painel usa a moldura de `NSMenu`, sem sobreposição de material, bordas ou seta.
A conferência inclui a composição real pelo WindowServer e interação com os controles
durante o tracking do menu.

No macOS 27, uma sonda de `NSSwitch`/SwiftUI com mínimo 14 e SDK 27.2 mede
54 × 24 pt. A mesma sonda com o SDK registrado como 14 mede 38 × 22 pt.
O build do app verifica SDK igual ao Xcode selecionado e mínimo 14 em cada
arquitetura antes da assinatura. O renderizador recebe a mesma configuração.

Na composição real do menu no macOS 27, o controle ligado foi verificado pela
acessibilidade como 54 × 24 pt e valor 1, com a cor verde oliva do sistema.
A conferência incluiu ausência de seta e de corte vertical, remoção da linha
redundante do caminho de áudio e atualização dos medidores com o menu aberto.
O ajuste do SDK foi validado também em um executável de teste universal
(arm64 + x86_64), com mínimo 14, SDK 27.2 e assinatura ad hoc válida em ambas
as arquiteturas.
