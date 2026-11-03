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
- Settings: valores padrão, round-trip (incluindo todas as `ChannelSelection`), esquema desconhecido e dados corrompidos → padrões, campos ausentes mantendo o padrão, valores fora de faixa limitados, debounce de 300 ms coalescendo várias mudanças numa gravação e gravação imediata dos campos de entrada padrão.

## Ferramenta de diagnóstico (`micboost-diag`)

CLI para verificar o hardware. É o meio pelo qual agentes sem acesso a áudio verificam o comportamento real. Pela regra de TCC, quem precisa de permissão de microfone é o app de terminal que a executa (Terminal, Orca etc.).

| Comando | Função |
|---|---|
| `micboost-diag devices [--json]` | Lista dispositivos com UID, transporte, canais, taxas, faixa de buffer, latências, safety offsets e elegibilidade; mostra o BlackHole detectado e a entrada padrão |
| `micboost-diag run --input <uid> [--gain-db N] [--buffer N] [--seconds N]` | Roda o motor sem UI (mesmo `EngineController` do app), imprimindo estado e contadores a cada segundo. Não altera a entrada padrão, a menos que `--manage-default-input` seja passado |
| `micboost-diag capture --device <uid> --seconds N --out file.wav` | Grava a entrada bruta de um dispositivo |
| `micboost-diag latency --input <uid> [--trials N]` | Mede a latência adicional (método abaixo) |
| `micboost-diag soak --input <uid> --minutes 60` | Ensaio de estabilidade (abaixo) |

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
| Latência adicional USB | C920, 16 kHz, buffer 256; 3 tentativas; correlação com som da sala | mediana/mín./máx. 38,875 ms; correlação 0,9994–0,99997; HAL parcial 19,25 ms; io_delta_host ≈ 834000 ticks |
| Latência adicional (mediana) | Bluetooth | — |
| CPU do processo | running, EQ ligado | — |
| Memória residente | running | — |
| Ensaio de 60 min | microfone interno | — |
| Captura bruta interna | 2026-11-03; pedido de 3 s, 48 kHz, 1 canal | 144000 frames; pico 0,102121599; RMS 0,005412710; sinal não zero |
| Captura bruta Continuity | 2026-11-03; pedido de 3 s, 48 kHz, 1 canal | 126976 frames; pico 0,003942308; RMS 0,001024310; sinal não zero |
| Latência de entrada reportada pela HAL | 2026-11-03; Continuity, 48 kHz | 6000 frames (125 ms) |

Microfone interno: a tampa fechada silencia a captura por hardware, embora a autorização seja concedida e os callbacks continuem. Captura de 2 s: 96000 frames, pico/RMS 0; medição de latência recusada por correlação 0. A latência interna em 128/256 permanece pendente com a tampa aberta. A fifine estava desconectada; a webcam USB substitui a segunda fonte por autorização do coordenador.

Captura bruta C920 (16 kHz, 2 s): 32000 frames; canal 1 pico 0,106262207 e RMS 0,015375519; canal 2 pico 0,092010498 e RMS 0,012545472. Captura simultânea de fonte/BlackHole durante a correlação: picos 0,15270996/0,15269819, 0,21069336/0,2104089 e 0,19293213/0,19246516; diferenças incluem o resampler de drift.

A recuperação física por desconexão USB, escuta humana e teste real de reinício de coreaudiod permanecem manuais. O ensaio de 60 min e as decisões de buffer/drift permanecem em validação.

(— = ainda não medido. Substituir pelo valor e pela data da medição.)
