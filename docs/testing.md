# Testes e medição

## Testes automatizados (`swift test`)

Rodam sem hardware de áudio, sem BlackHole e sem permissão de microfone. Usam o Swift Testing (`import Testing`).

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
- Settings: valores padrão, round-trip e esquema corrompido → padrões.

## Ferramenta de diagnóstico (`micboost-diag`)

CLI para verificar o hardware. É o meio pelo qual agentes sem acesso a áudio verificam o comportamento real. Pela regra de TCC, quem precisa de permissão de microfone é o app de terminal que a executa (Terminal, Orca etc.).

| Comando | Função |
|---|---|
| `micboost-diag devices [--json]` | Lista dispositivos com UID, transporte, canais, taxas, faixa de buffer, latências, safety offsets e elegibilidade; mostra o BlackHole detectado e a entrada padrão |
| `micboost-diag run --input <uid> [--gain-db N] [--buffer N] [--seconds N]` | Roda o motor sem UI (mesmo `EngineController` do app), imprimindo estado e contadores a cada segundo. Não altera a entrada padrão, a menos que `--manage-default-input` seja passado |
| `micboost-diag capture --device <uid> --seconds N --out file.wav` | Grava a entrada bruta de um dispositivo (validação da etapa 0) |
| `micboost-diag latency --input <uid> [--trials N]` | Mede a latência adicional (método abaixo) |
| `micboost-diag soak --input <uid> --minutes 60` | Ensaio de estabilidade (abaixo) |

## Medição de latência

**Fronteira medida:** da amostra disponível na fonte até a mesma amostra disponível para um leitor do BlackHole. Esse é o atraso acrescentado pelo MicBoost em relação a um app que lesse o microfone diretamente. O atraso dos apps consumidores (Zoom, gravadores) é medido à parte, quando relevante, e não entra nessa conta.

Método (`micboost-diag latency`):
1. O motor roda no próprio processo da ferramenta (fonte → BlackHole, ganho 0 dB, EQ desligado).
2. Dois IOProcs auxiliares de captura, um direto na fonte e outro na entrada do BlackHole, gravam com o `mHostTime` do início de cada buffer em buffers pré-alocados.
3. Um clique (impulso de 1 ms) é tocado na saída padrão (`afplay` ou um IOProc de saída). Em alternativa, o usuário estala os dedos perto do microfone.
4. A ferramenta alinha as duas gravações pelo host time, calcula a correlação cruzada e obtém o atraso. Repete N vezes (padrão 10) e reporta mediana, mínimo e máximo, em ms e em frames.
5. Também imprime a latência reportada pela HAL e `io_delta_host`, para comparar.

**Meta:** mediana < 20 ms na máquina de referência com buffer de 256 (e o valor com 128). É uma meta de engenharia, não uma garantia. Desvios são documentados abaixo.

## Ensaio de estabilidade (60 min)

`micboost-diag soak`:
- roda o motor com a fonte real;
- a cada 60 s, mede a latência pelo método acima, com o clique ou com o próprio sinal da sala por correlação;
- registra overloads, `input_missing`, `nonfinite_resets`, CPU (`task_info`) e memória residente.

Aprovação:
- deriva de latência entre o primeiro e o último minuto < 1 ms;
- 0 overloads;
- 0 `nonfinite_resets`;
- memória estável (±1 MB).

Complementar com uma escuta humana de uma gravação de voz de 60 min via BlackHole, procurando cortes e estalos.

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

Máquina de referência: MacBook Neo (Apple A18 Pro), macOS 27.2.

| Medida | Condição | Resultado |
|---|---|---|
| Latência adicional (mediana) | microfone interno, 48 kHz, buffer 256 | — |
| Latência adicional (mediana) | microfone interno, 48 kHz, buffer 128 | — |
| Latência adicional (mediana) | USB/interface | — |
| Latência adicional (mediana) | Bluetooth | — |
| CPU do processo | running, EQ ligado | — |
| Memória residente | running | — |
| Ensaio de 60 min | microfone interno | — |

(— = ainda não medido. Substituir pelo valor e pela data da medição.)

### Diagnóstico disponível na etapa 0

Somente `devices [--json]` e `capture` estão implementados. A saída textual lista também elegibilidade e BlackHole; o JSON é o `DeviceSnapshot` com `devices` e `defaultInputUID` (os predicados de elegibilidade e BlackHole são derivados dos campos). `capture` aceita duração positiva de até 300 segundos, grava WAV IEEE Float32 intercalado na taxa nominal e imprime frames efetivamente capturados, pico e RMS lineares por canal. A duração inclui a partida do dispositivo; Continuity pode entregar menos frames durante a conexão. Formatos diferentes de Float32 nativo são recusados sem alterar o hardware.

Verificação da etapa 0 na máquina de referência (2026-11-03):

| Medida | Condição | Resultado |
|---|---|---|
| Captura bruta interna | pedido de 3 s, 48 kHz, 1 canal | 144000 frames; pico 0,102121599; RMS 0,005412710; sinal não zero |
| Captura bruta Continuity | pedido de 3 s, 48 kHz, 1 canal | 126976 frames; pico 0,003942308; RMS 0,001024310; sinal não zero |
| Enumeração BlackHole | driver instalado, ainda ausente na HAL | UID real pendente; não reiniciado coreaudiod |

Nenhuma entrada ou saída padrão foi alterada. Capturas locais ficam em `.scratch/` e não entram no git. A ausência de BlackHole mantém a etapa 0 em andamento. Testes automatizados desta etapa cobrem enumeração/elegibilidade, detecção primária e alternativa, coalescência, remoção de listeners, guarda de saída padrão e cópia/limites do buffer de captura; os testes de motor e DSP descritos acima pertencem às próximas etapas.

`swift build`, `swift test` (2 testes C/captura + 5 Core) e `scripts/build-app.sh debug` passam; o teste negativo da fake registra uma issue esperada com `withKnownIssue`. `codesign --verify --strict` passa. `open build/MicBoost.app` iniciou o processo, mas a presença visual do item de status não foi confirmada: o provedor de automação disponível não suporta a superfície da barra de menus.
