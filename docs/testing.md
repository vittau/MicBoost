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
- Nunca chama a escrita da saída padrão. A fake falha o teste se isso acontecer, inclusive com o monitor ligado e a saída padrão trocando.
- Modo monitor ([audio-engine.md](audio-engine.md#modo-monitor)): agregado com a saída em terceiro e compensação de drift; saída igual à fonte sem duplicar subdispositivo; mapa de canais de monitor com saída de 1, 2 e 8 canais; saída BlackHole, agregado com BlackHole e sem saída → `unavailable` com o motor em `running`; taxa de trabalho entre os três e saída sem taxa comum → sem monitor; taxa da saída restaurada ao desligar; ligar/desligar reconstrói sem tocar a entrada padrão; troca da saída padrão e saída removida reconstroem sem `error`; falha de start com a saída → novo start sem ela; eventos `Devices` da criação do agregado não repetem builds quando o monitor está indisponível ou em fallback; toggle parado/em erro só guarda intenção; recovery/wake não restauram taxas; monitor desligado ou trocado restaura somente a saída que deixa o agregado, preservando fonte duplex e taxas alteradas externamente.
- Elegibilidade de fontes: exclui as variantes de BlackHole, o próprio agregado e agregados com BlackHole.
- Máquina de estados: transições de [architecture.md](architecture.md#ciclo-de-vida-do-motor) para cada evento de recuperação.
- Recuperação, uma por linha da tabela de [audio-engine.md](audio-engine.md#recuperação): fonte perdida e devolvida; BlackHole removido e devolvido; taxa da fonte e do BlackHole alterada de fora; permissão negada e concedida; suspensão e retomada com sucesso e com falha; `coreaudiod` reiniciado com IDs novos; overload só incrementando o contador; notificação da própria escrita de taxa e mudança de latência/faixa de buffer sem reconstrução. O caminho percorrido é verificado pelo observador de estado, não por polling do estado final.
- Taxa de trabalho: seleção com 48 kHz disponível, só 16/24/32 kHz (picks 32 kHz quando o destino os oferece), só 88,2/96 kHz e sem taxa em comum; aplicação nas duas pontas; restauração no stop voluntário e na troca de fonte; nada restaurado após mudança externa, nem em erro do motor.
- Mapa de canais: fontes com 1, 2 e 8 canais, streams intercalados e não intercalados, fonte com saídas próprias.
- Settings: valores padrão, round-trip (incluindo todas as `ChannelSelection`), esquema desconhecido e dados corrompidos → padrões, campos ausentes mantendo o padrão, valores fora de faixa limitados, debounce de 300 ms coalescendo várias mudanças numa gravação e gravação imediata dos campos de entrada padrão.

### `MicBoostUITests`

- Mapeamento de `AppModel` para cada linha de [ui.md](ui.md#mensagens-de-estado): estado do motor → mensagem, ação da faixa e ícone; a mensagem de BlackHole ausente some sozinha quando o motor volta a `running`.
- Fonte desconectada: a linha da lista e a faixa usam o último nome conhecido daquele UID, inclusive o nome persistido quando o app abre com o dispositivo ausente; sem nome conhecido, a linha mostra o rótulo genérico, nunca o UID.
- Carência de 1,5 s: uma ausência de dispositivo que dura menos que isso (reinício do `coreaudiod`) não mostra faixa; a faixa aparece quando a condição persiste. A linha de entrada do sistema e a lista de microfones mantêm o último estado conhecido durante a carência.
- Linha de entrada do sistema: BlackHole como entrada padrão mostra "MicBoost" com marcação só com o motor rodando; divergência mostra o nome com "Usar MicBoost" habilitado quando o clique funciona; entrada desconhecida não mostra botão.
- Catálogo de strings: toda chave passada a `localized(...)` ou `String(localized:)` em `MicBoostUI` e `MicBoostApp` existe nos dois `.strings`, os dois catálogos têm exatamente as mesmas chaves e cada tradução preserva os placeholders da chave.
- Permissão reavaliada ao ativar o app: negada mantém a faixa, concedida limpa e tenta iniciar de novo.
- Linha do monitor: o clique no switch (`mouseUp`) liga e desliga o monitor no `AppModel`; a linha de texto aparece e some com o switch e mostra cada `MonitorStatus`, inclusive o aviso de atraso acima de 50 ms; o switch fica desabilitado com o processamento desligado.
- Formatação de ganho e escala dos medidores; o medidor ignora o mouse e o foco, e os valores de ganho e de frequência são texto somente leitura.
- Frequência do EQ: a grade quantiza nos limites das faixas de degrau (195, 199, 200, 950, 999, 1000, 1240, 1250, 9750, 9999, 10000, 10400 e 14000 Hz), os padrões e os limites de banda estão na grade, as setas andam para o valor seguinte ou anterior e param nos limites; o mapeamento logarítmico posição ↔ Hz volta ao mesmo valor e o meio da escala é a média geométrica.
- Slider de frequência do menu: o arrasto (posição logarítmica → Hz → grade → faixa) grava a frequência da banda no `AppModel`, o rótulo e o valor de acessibilidade mostram "1000 Hz", o knob não se move com atualizações do modelo durante o arrasto, um valor persistido fora da grade aparece como está até o slider se mover e o máximo do slider segue 0,45 · fs da taxa atual.
- Encerramento (`TerminationBarrier`): o quit só responde `reply(toApplicationShouldTerminate:)` depois do `shutdown`; um segundo ⌘Q durante o stop não encurta a espera; um stop pendurado responde no prazo, antes de o stop terminar; um stop que falha também encerra. Os testes esperam o evento de resposta, não um relógio: a suíte divide o ator principal com as demais linhas de UI, cujo trabalho de AppKit segura a thread principal por segundos no runner do CI.

## Ferramenta de diagnóstico (`micboost-diag`)

CLI para verificar o hardware. `run` e `latency` aceitam `--gain-db N`, `--mute`, `--eq-low F:G`, `--eq-mid F:G:Q`, `--eq-high F:G` e `--eq-off`; os valores são validados e limitados às faixas de settings. Os controles de diagnóstico ficam em domínio de preferências separado do app. `run` publica pico de entrada, pico de saída, GR e CPU acumulada a cada segundo. `run`, `latency` e `soak` não alteram as entradas ou saídas padrão; a política de entrada padrão ainda não está integrada a esses comandos. `latency` aceita `--buffer`; `soak` aceita `--buffer` e usa 20 minutos quando `--minutes` não é informado. A opção `permission` imprime o estado de autorização do microfone sem solicitar acesso.

É o meio pelo qual agentes sem acesso a áudio verificam o comportamento real. Pela regra de TCC, quem precisa de permissão de microfone é o app de terminal que a executa (Terminal, Orca etc.).

| Comando | Função |
|---|---|
| `micboost-diag devices [--json]` | Lista dispositivos com UID, transporte, canais, taxas, faixa de buffer, latências, safety offsets e elegibilidade; mostra o BlackHole detectado, entrada e saída padrão e os componentes HAL de latência dos dispositivos internos |
| `micboost-diag set-rate --device <uid> --rate <hz>` | Define a taxa nominal de um dispositivo e confirma o valor aplicado; usado no teste de mudança de formato e para devolver o BlackHole a 48000 Hz. Não altera entradas ou saídas padrão |
| `micboost-diag run --input <uid> [--buffer N] [--seconds N] [--monitor --monitor-silent]` | Roda o motor sem UI (mesmo `EngineController` do app), imprimindo estado e contadores a cada segundo e cada transição de estado com o instante. Não altera a entrada ou saída padrão; integração com a política de entrada padrão fica para o app |
| `micboost-diag capture --device <uid> --seconds N --out file.wav` | Grava a entrada bruta de um dispositivo |
| `micboost-diag latency --input <uid> [--trials N]` | Mede a latência adicional (método abaixo) |
| `micboost-diag monitor-latency --input <uid> [--output <uid>] [--buffer N] [--trials N]` | Mede silenciosamente a latência adicionada pelo MicBoost (fonte → BlackHole com monitor no agregado) e imprime a estimativa física total como contexto, [método abaixo](#medição-de-latência-do-monitor). Sem `--output`, usa a saída padrão; exige mantenedor presente se a saída forem os alto-falantes do Mac |
| `micboost-diag soak --input <uid> [--minutes N]` (padrão 20) | Ensaio de estabilidade (abaixo) |

`set-rate` limita a taxa às `AvailableNominalSampleRates` do dispositivo, escreve `kAudioDevicePropertyNominalSampleRate` e espera até 1 s pelo valor aplicado, porque a HAL aplica a mudança de forma assíncrona. Se o dispositivo mantiver outra taxa (por exemplo, enquanto é subdispositivo de um agregado em uso), imprime o valor real e sai com erro. `run` imprime uma linha `event state=… t_ms=…` por transição, o que dá o tempo de retorno a `running`.

A CLI usa parsing manual, sem dependências externas. `devices` exibe transporte por nome, taxas como lista simples em Hz (intervalos quando aplicável), latências e safety offsets em frames e milissegundos na taxa nominal. O JSON preserva os valores numéricos do `DeviceSnapshot` (`devices` e `defaultInputUID`); elegibilidade e BlackHole são derivados dos campos.

`capture` aceita duração positiva de até 300 segundos e grava WAV IEEE Float32 intercalado na taxa nominal. Imprime frames efetivamente capturados, pico, RMS e contagem de amostras acima de −1 dBFS (0,8913) por canal. A contagem mede o teto do limitador na saída do BlackHole sem depender do WAV. A duração inclui a partida do dispositivo; Continuity pode entregar menos frames durante a conexão. A extensão de `CoreAudioHardware` valida os formatos virtuais Float32 nativos sem modificar formatos ou padrões, cria um IOProc C e pré-aloca o buffer em `mb_capture_create`. O callback apenas copia amostras; gravação WAV e cálculo de pico/RMS acontecem após stop e destruição do IOProc. Outros formatos são recusados sem alterar o hardware. Capturas locais ficam em `.scratch/` e não entram no git.

## Medição de latência

**Fronteira medida:** da amostra disponível na fonte até a mesma amostra disponível para um leitor do BlackHole. Esse é o atraso acrescentado pelo MicBoost em relação a um app que lesse o microfone diretamente. O atraso dos apps consumidores (Zoom, gravadores) é medido à parte, quando relevante, e não entra nessa conta.

Método (`micboost-diag latency`):
1. O motor roda no próprio processo da ferramenta (fonte → BlackHole, ganho 0 dB, EQ desligado).
2. Dois IOProcs auxiliares de captura, um direto na fonte e outro na entrada do BlackHole, gravam com o `mHostTime` do início de cada buffer em buffers pré-alocados.
3. A implementação usa o sinal da sala, sem emitir sons. Um clique (impulso de 1 ms) é tocado na saída padrão (`afplay` ou um IOProc de saída). Em alternativa, o usuário estala os dedos perto do microfone.
4. A ferramenta captura dois segundos por tentativa, usa o host time do primeiro buffer para alinhamento, busca correlação normalizada em ±100 ms e exige correlação ≥ 0,5; sem sinal suficiente, falha explicitamente. A ferramenta alinha as duas gravações pelo host time, calcula a correlação cruzada e obtém o atraso. Repete N vezes (padrão 10) e reporta mediana, mínimo e máximo, em ms e em frames.
5. Também imprime a latência reportada pela HAL e `io_delta_host`, para comparar.

**Aceitação (v1, fonte → BlackHole):** mediana ≤ 100 ms em toda fonte suportada, exceto fontes cuja própria latência de entrada reportada já exceda esse valor (por exemplo, Continuity), que ficam documentadas como limitação.

**Objetivo de engenharia:** mediana fonte → BlackHole < 20 ms no buffer padrão de 256 frames para fontes USB e internas a 48 kHz, também adotada como critério de latência adicionada do [modo monitor](#medição-de-latência-do-monitor) quando o subdispositivo de monitor está presente no agregado; desvios são registrados abaixo com a causa.

## Medição de latência do monitor

`micboost-diag monitor-latency --input <uid> [--output <uid>] [--buffer N] [--trials N]`
usa a saída indicada ou, sem `--output`, a saída padrão, sem alterá-la.

1. O motor mantém a saída de monitor no agregado, com os mesmos streams e timing do
   monitor normal. Um atômico exclusivo do diagnóstico, definido antes do start e lido
   uma vez por ciclo, faz o IOProc escrever zeros nos canais do monitor. O app não ativa
   esse atômico. Ganho de 0 dB e EQ desligado.
2. A correlação cruzada existente mede fonte → BlackHole usando apenas o som ambiente,
   sem gerar sinal. Correlação inferior a 0,5 falha explicitamente e orienta estalar os
   dedos perto do microfone antes de repetir.
3. O resultado principal, `monitor_added_ms`, é a ponte fonte → BlackHole medida com o
   subdispositivo de monitor presente: BlackHole e monitor são escritos no mesmo ciclo.
   A estimativa física total, `monitor_physical_estimate_ms`, soma três parcelas: latência de entrada da fonte (dispositivo,
   safety offset e maior latência dos streams de entrada, HAL no escopo de entrada),
   medição fonte → BlackHole e latência da saída (dispositivo, safety offset e maior
   latência dos streams de saída, HAL no escopo de saída). A medição da ponte cancela
   a latência física de entrada, comum às duas capturas, por isso ela é acrescentada
   explicitamente. A ferramenta imprime todos os termos em frames, os subtotais em ms,
   a soma e a latência reportada completa do monitor. As parcelas físicas de entrada e
   saída são **reportadas pela HAL**, não medidas fisicamente.
4. Repete N tentativas (padrão 10), com mediana, mínimo e máximo da latência adicionada
   em ms e frames; imprime separadamente o resumo da estimativa física total em ms.

Aceitação: mediana da **latência adicionada pelo MicBoost < 20 ms**, medida na ponte
fonte → BlackHole com o subdispositivo de monitor presente, buffer 256 a 48 kHz, fonte
interna ou USB e saída interna ou com fio. Dispositivo, safety offset e stream de
entrada e saída são contexto e não entram no critério. A escuta real com fones é validação manual com o mantenedor.
Quando a saída for os alto-falantes do Mac, inclusive neste modo silencioso, o ensaio
só pode ser executado com o mantenedor presente e a pedido dele.
`run --monitor` exige `--monitor-silent`; o diagnóstico não emite voz na saída física.

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
2. Primeira abertura com ajustes zerados (`defaults delete io.github.vittau.MicBoost`) no build da release: permissão de microfone, microfone escolhido automaticamente, troca de microfone clicando na lista, mensagem sem BlackHole, painel abrindo automaticamente.
3. Microfone interno e um USB ou interface: voz amplificada em um app de chamada (FaceTime ou Zoom) e em um gravador (QuickTime ou Voice Memos), com o app em "padrão do sistema" e em "BlackHole 2ch".
4. Ganho acima de +6 dB com "Limitando" visível ao gritar; mute; EQ nos extremos; bypass; "Zerar EQ"; nenhum clique perceptível ao mexer nos controles com voz.
5. Fechar e abrir o painel durante uma chamada: o áudio não é interrompido.
6. Recuperação, item a item, conforme a seção abaixo.
7. Sair do app: a entrada anterior é restaurada (e não é restaurada se o usuário tiver mudado manualmente).
8. Bluetooth (AirPods ou similar): registrar taxa, latência medida e degradação da saída do fone.
9. VoiceOver, navegação por teclado, aparência clara/escura, Reduzir transparência e Reduzir movimento.
10. Persistência: reabrir o app e conferir ganho, mute, EQ, fonte e canais.

### Recuperação (etapa 5)

Preparação para todos os itens: app aberto com processamento ligado, microfone USB escolhido, BlackHole 2ch como entrada padrão e um app de chamada ouvindo BlackHole (para ouvir o silêncio e a volta). Antes de cada item, anotar a entrada padrão com
`swift run micboost-diag devices` (primeira linha) e a taxa do BlackHole.

| # | Passos | Mensagem esperada no painel | Entrada padrão esperada |
|---|---|---|---|
| 1 | Com o áudio tocando, desconectar o microfone USB; esperar 5 s; reconectar | "<nome> desconectado. O áudio volta quando ele for reconectado." durante a ausência; a faixa some quando ele volta, sem escolher outro microfone | continua BlackHole 2ch; volta a tocar no mesmo microfone |
| 2 | Suspender o Mac (menu Apple → Suspender) e acordar | nenhuma durante o sono; ícone volta a "ativo" cerca de 1 s depois de acordar. Se a tentativa falhar, a faixa "Falha no áudio do sistema." aparece com "Tentar novamente" | continua BlackHole 2ch |
| 3 | `sudo killall coreaudiod` com o áudio tocando; esperar 10 s | nenhuma faixa e nenhuma troca da linha de entrada do sistema; áudio volta sozinho | continua BlackHole 2ch |
| 4 | Ajustes do Sistema → Privacidade e Segurança → Microfone: desligar o MicBoost; voltar ao app; religar a permissão e voltar ao app | com a permissão desligada, "O MicBoost não tem acesso ao microfone." com "Abrir Ajustes de Privacidade"; ao religar e voltar ao app a faixa some e o áudio volta | continua BlackHole 2ch |
| 5 | Com o áudio tocando: `sudo mv /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver /tmp/` e `sudo killall coreaudiod`. Depois: `sudo mv /tmp/BlackHole2ch.driver /Library/Audio/Plug-Ins/HAL/` e `sudo killall coreaudiod` | "BlackHole 2ch não encontrado." com "Como instalar" enquanto o driver está ausente; a faixa some sozinha quando ele volta | continua a entrada que estava em uso; nada é escrito enquanto falta o BlackHole |
| 6 | Em Ajustes do Sistema → Som → Entrada, escolher outro microfone; no painel, clicar em "Usar MicBoost" | linha "Entrada do sistema: <nome>" com "Usar MicBoost"; depois "Entrada do sistema: MicBoost" com marcação. Trocar a entrada de novo deve marcar divergência sem reverter sozinho | volta a BlackHole 2ch só depois do clique no botão |
| 7 | Mudar a taxa do microfone e do BlackHole em Configuração de Áudio e MIDI com o áudio tocando | nenhuma faixa; o áudio volta em ~1 s (o motor reaplica a taxa de trabalho: 48 kHz ou a melhor comum) | continua BlackHole 2ch |
| 8 | Sair do app (Sair do MicBoost) | — | a entrada anterior é restaurada e as taxas que o MicBoost mudou voltam às originais |

## Resultados registrados

### Modo monitor — 04/11/2026

MacBook Neo, fonte `BuiltInMicrophoneDevice`, saída padrão `BuiltInSpeakerDevice`,
48 kHz. Os ensaios com monitor silencioso e a escuta manual estão **pendentes** de
sessão com o mantenedor. Nenhum ensaio com monitor é autorizado sem sua presença
quando a saída forem os alto-falantes do Mac.

Decomposição somente leitura por `swift run micboost-diag devices`:

| Parcela | Dispositivo | Safety | Stream | Total |
|---|---:|---:|---:|---:|
| Entrada interna | 26 | 48 | 1439 | 1513 frames (31,521 ms) |
| Saída interna | 69 | 48 | 425 | 542 frames (11,292 ms) |
| Dois buffers de 256 | — | — | — | 512 frames (10,667 ms) |

A fórmula reportada soma cada termo uma vez: `(1513 + 542 + 512) / 48 = 53,479 ms`.
Não há dupla contagem identificada; omitir os streams produziria 14,646 ms e esconderia
38,833 ms. Teste unitário usa esses valores para impedir regressão.

O registro acústico de 55,792 ms foi obtido antes da regra que proíbe ensaios
nos alto-falantes sem o mantenedor e não é evidência de aceitação: inclui a propagação no ar e
uma segunda captura do eco pelo microfone. A diferença para os ~15,1 ms do caminho
fonte → BlackHole é compatível principalmente com a latência de captura física
(31,521 ms) e a saída (11,292 ms), com ressalva de que timestamps e resampling tornam
essa comparação aproximada. A autocorrelação ficou instável e falhou em seguida
(correlação 0,130968); não se pode atribuir o excesso ao resampler de drift isoladamente.

Verificação permitida sem monitor:
`swift run micboost-diag latency --input BuiltInMicrophoneDevice --trials 10 --buffer 256`:
mediana 13,1875 ms, mínimo 13,1875 ms, máximo 13,2083 ms (633–634 frames),
zero overloads e `input_missing`; `io_delta_ms = 12,7292`. O log existente com
subdispositivo de monitor registrou fonte → BlackHole em 15,1042 ms de mediana,
mínimo 15,1042 e máximo 15,1250 ms; `io_delta_ms = 14,6458`. A diferença de
aproximadamente 1,917 ms aparece também no timing do IOProc, muito menor que os
~40 ms do valor acústico; não identifica isoladamente custo de drift ou de buffer.
As condições não foram repetidas com monitor e a comparação não é ensaio controlado.
Os 13,19 ms sem monitor e os 15,10 ms com o subdispositivo de monitor no ensaio
anterior à regra são apenas contexto; a aceitação de < 20 ms permanece pendente
de ensaio com monitor e mantenedor presente.

`swift build` e `swift format lint --strict --recursive Sources Tests Package.swift`
aprovados; `swift test`: 143 testes (53 UI em 1,256 s, 12 DSP em 0,136 s,
78 Core em 0,931 s, incluindo um caso conhecido da HAL falsa), total dos targets
2,323 s sem compilação. Capturas do painel regeneradas com monitor desligado.
Entrada e saída padrão conferidas ao encerrar: `BuiltInMicrophoneDevice` e
`BuiltInSpeakerDevice`. Nenhum processo de diagnóstico permaneceu em execução.

Para confirmar com o mantenedor: comparar fonte → BlackHole com e sem subdispositivo
de monitor nos buffers 256 e 128; obter a soma silenciosa por tentativa e os componentes
HAL durante cada start. Se 256 não atingir a meta, medir 128 e 64, sem mudar o padrão.
A estimativa física ilustrativa completa usa os termos de entrada que a correlação da ponte
cancela: `31,5208 + 13,1875 + 11,2917 = 56,0000 ms`, próxima dos 55,792 ms do
registro acústico anterior à regra. Esse cruzamento explica a ordem de grandeza da
anomalia; não substitui medição com monitor presente nem prova aceitação. A meta
< 20 ms se refere somente à ponte medida com monitor no agregado, não a essa soma. Com a ponte
registrada no ensaio antigo com monitor (15,1042 ms), a soma seria 57,9167 ms; as
condições diferentes e a instabilidade acústica impedem comparação de precisão.

Pendentes:
- `swift run micboost-diag monitor-latency --input BuiltInMicrophoneDevice --trials 10 --buffer 256`
  (e buffers 128/64 conforme necessário), com saída interna e mantenedor presente;
- `swift run micboost-diag run --input BuiltInMicrophoneDevice --seconds 60 --buffer 256 --monitor --monitor-silent`;
- escuta com fones, troca de saída e toggle no app com o mantenedor.

### Testes manuais com o mantenedor (2026-11-03/04)

fifine USB a 48 kHz, Mono 1, buffer 256, EQ no padrão de voz, voz falada na distância de uso. Níveis medidos com `micboost-diag capture --device BlackHole2ch_UID` (10 s, RMS em janelas de 100 ms):

| Ganho | Voz (mediana / p90) | Pico | Ruído de fundo |
|---|---|---|---|
| 0 dB | −46,2 / −42,0 dBFS | −23,4 dBFS | −63,4 dBFS |
| +18 dB | −28,9 / −24,6 dBFS | −6,1 dBFS | −51,1 dBFS |
| +24 dB | −20,4 / −17,3 dBFS | −1,6 dBFS | −42,6 dBFS |

- Calibração: com esse microfone, a voz chega ao nível de chamada (≈ −20 dBFS) só no máximo de +24 dB; a faixa atual é necessária e suficiente.
- Proteção de pico: palmas a +24 dB acionaram "Limitador ativo", mas o BlackHole recebeu picos de até 1,1845 (+1,47 dBFS), com 118 amostras acima do teto de 0,891; as amostras alternam de sinal quase a cada amostra. O DSP limita a 0,891 e corta em ±1, então o excesso vem do resampler de drift do agregado, aplicado ao BlackHole depois do limitador. O teto passou a valer com o BlackHole como relógio principal ([audio-engine.md](audio-engine.md#decisão-dispositivo-agregado-privado-com-um-único-ioproc)); a confirmação medida está na entrada de 2026-11-04 abaixo.
- Recuperação aprovada no app real: desconectar e reconectar o microfone USB; `killall coreaudiod` (o áudio volta sozinho; as faixas de dispositivo ausente durante o reinício foram eliminadas pela carência de 1,5 s); permissão de microfone negada e concedida (o macOS oferece "Encerrar e Reabrir" ao mudar a permissão com o app aberto; depois de reaberto, o áudio volta); troca manual da entrada padrão com "Usar MicBoost" (sem disputa); mudança de taxa do BlackHole no Configuração de Áudio e MIDI.
- Menu nativo aprovado: sliders de ganho, largura e frequência, faixa traduzida, botão de apoio, alinhamento sem coluna de marca.
- Pendentes: BlackHole ausente (remoção do driver), suspensão e retomada, restauração da entrada ao sair depois de divergir e usar "Usar MicBoost" duas vezes (correção na HAL falsa, falta o app real), medidores somente leitura, ganho e frequência sem campo no app real, VoiceOver e preferências de acessibilidade.

### Relógio do agregado e teto no BlackHole (2026-11-04)

Fifine USB a 48 kHz, Mono 1, buffer 256, EQ no padrão de voz, ganho +24 dB. Motor rodando por `micboost-diag run` e, em paralelo, `micboost-diag capture --device BlackHole2ch_UID --seconds 60`; o mantenedor palmeou 3–4 vezes, na mesma distância e força, nas duas execuções. "Antes" é o binário do `main` (601f58d), com a fonte como relógio principal e o resampler de drift no BlackHole; "depois" é o binário desta mudança, com o BlackHole como relógio principal e o resampler na fonte. A contagem de amostras acima de −1 dBFS veio do resumo novo do `capture` e foi conferida lendo o WAV gravado.

| Execução | Pico de saída do motor | GR máximo | Pico no BlackHole | Amostras acima de −1 dBFS |
|---|---|---|---|---|
| antes (main) | 0,891 | 25,0 dB | 1,0700 (+0,59 dBFS) | 752 por canal |
| depois | 0,891 | 26,2 dB | 0,8910 (−1,00 dBFS) | 0 |

- O pico de entrada chegou a 1,0 (antes) e 1,1541 (depois) com as palmas, ou seja, o microfone saturou e o limitador trabalhou nos dois casos; L = R nas duas capturas. `input_missing`, `nonfinite_resets` e overloads ficaram em 0 nas duas execuções.
- `io_delta_host` subiu de 13,25 ms (antes) para 15,83 ms (depois) no buffer 256, coerente com o buffer inteiro a mais entre entrada e saída; a latência medida não mudou.
- O mesmo teste não foi refeito com ar normal: a fala não chega ao teto, então a diferença entre os dois arranjos só aparece em transientes.

Latência adicional com o novo relógio, 3 tentativas cada (mediana / mín. / máx.):

| Fonte | Buffer | Latência | HAL reportada |
|---|---|---|---|
| fifine, 48 kHz | 64 | 7,29 / 7,29 / 7,31 ms | 7,5 ms |
| fifine, 48 kHz | 128 | 9,96 / 9,94 / 9,96 ms | 8,83 ms |
| fifine, 48 kHz | 256 | 15,29 / 15,27 / 15,29 ms | 11,5 ms |
| C920, 16 kHz | 256 | não medido: dispositivo ausente da máquina nesta janela | — |

As três medições do fifine repetem os valores de 2026-11-03 (7,29, 9,96 e 15,31 ms), então a troca de relógio não custa latência. A C920 continua com o valor de 38,94 ms registrado em 2026-11-03, medido antes da troca de relógio e não remedido.

Ensaio de estabilidade, fifine a 48 kHz, buffer 256, 20 min:

- latência por minuto entre 15,2917 e 15,3125 ms; primeiro e último minuto 15,2917 ms, deriva 0,0 ms (amplitude 0,02 ms);
- 0 overloads, 0 `input_missing`, 0 `nonfinite_resets`;
- RSS instantânea 17,8–21,0 MB (pico 21,2 MB), sem tendência de crescimento depois do minuto 13;
- CPU 9,21 s em 20 min (≈ 0,77% de um núcleo);
- correlação da medição de latência entre 0,994 e 0,999 em todas as 20 tentativas.

Estado final da máquina: BlackHole a 48000 Hz (`set-rate`), entrada padrão `BlackHole2ch_UID` como estava ao abrir a janela (nenhum comando de diagnóstico altera a entrada padrão), fifine a 48000 Hz, nenhum processo `micboost-diag` ou `MicBoost.app` iniciado pela tarefa.

Testes automatizados desta mudança: 119 testes (64 Core, 11 DSP, 44 UI) com execução somada em torno de 2 s, a maior suíte em 0,65 s; dois testes novos cobrem a descrição do agregado (BlackHole como principal, compensação só na fonte) e o caminho do `EngineController` até a HAL falsa. `swift build`, `swift test` e lint de formatação recursivo passam.


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
- A queda lenta de latência do ensaio de 20 min com a C920 (2026-11-03) é anterior à troca de relógio e não se repetiu no fifine com o novo arranjo, que ficou em 0,0 ms de deriva. Se ela dependia do resampler no BlackHole, o arranjo atual a elimina; um ensaio de várias horas continua decidindo.
- Reinício real do `coreaudiod` e escuta humana são verificações manuais. A HAL falsa cobre perda e retorno da fonte e do BlackHole. As transições de estado do motor ficam no log unificado, na categoria `engine`: aplicar, por exemplo, `log show --last 5m --info --predicate 'subsystem == "io.github.vittau.MicBoost"'` depois de um teste manual.

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

Verificação automatizada da interface: 107 testes (38 UI, 11 DSP, 58 Core),
execução somada de aproximadamente 1,8 s; a suíte Core inclui o caso negativo
`fakeRejectsOutputWrite`, que registra uma issue conhecida intencionalmente.
`swift build`, `swift test`, lint recursivo de formatação, montagem debug e
`codesign --verify --strict` passam na máquina de referência.

O painel é um `NSMenu` de itens reais: lista de microfones, "Ajustes…" (⌘,), "Sair do
MicBoost" (⌘Q), cabeçalhos de seção e separadores. A conferência inclui a composição real
pelo WindowServer, com hover, destaque e atalhos desenhados pelo AppKit.

Menu nativo (2026-11-03): as capturas passaram a vir do menu real aberto pelo auxiliar e
capturado com `SCScreenshotManager`, porque o painel não é mais uma view SwiftUI. Dimensões
em 1×: `eq-*` 320 × 601, `panel-*` 320 × 306, `error-*` 320 × 361, `settings-*` 540 × 853.
As linhas de view alinham com o título dos itens nativos: o menu abre sem a coluna de
marcação (`showsStateColumn = false`), o auxiliar mede as insets do próprio menu na primeira
abertura (título de item sem imagem e coluna de atalho) e as linhas passam a usá-las. Na
captura final, as linhas de view começam em 15 pt e os itens nativos "Ajustes…" e "Sair do
MicBoost" em 17 pt — a diferença é o desenho do glifo, não a coluna. A fonte selecionada é
marcada por um selo circular de 18 pt com a cor de destaque (sem coluna de marcação, sem
checkmark), e "Ajustes…" fica em texto puro, sem o ícone automático que o macOS 27 desenha
em itens com ⌘, Clicar no cabeçalho do EQ durante o tracking insere o
item das bandas e o menu passa de 377 para 601 pt de altura na mesma sessão; esconder o
item não redimensiona o menu, por isso as linhas condicionais são inseridas e removidas.

Os medidores são `NSLevelIndicator` (`continuousCapacity`, `.small`): o controle nativo tem
16 pt de altura intrínseca no macOS 27, com preenchimento na cor de destaque do sistema. As duas barras
das capturas clara e escura mostram 0 dBFS preenchendo a faixa e −1 dBFS em 89,13% dela na
escala de amplitude linear; valores ≤ −60 dBFS ficam em zero. `warningValue` e
`criticalValue` ficam acima do máximo, então nenhuma captura mostra amarelo ou vermelho.
O teste de proporcionalidade confere que +6,0206 dB dobra o comprimento para amplitudes de
entrada de 0,01, 0,1 e 0,4.

Sliders do painel em `NSSlider` (2026-11-03; frequências em 2026-11-04): os oito sliders do
painel — ganho, ganho e frequência das três bandas e largura — são `NSSlider` puro dentro das
views de item, porque o `Slider` do SwiftUI podia perder o mouse-up no tracking do menu e ficar
preso no estado pressionado. O knob só acompanha valores externos quando não há arrasto, e as
setas andam 0,5 dB (1 dB com ⌥), 0,1 de Q ou o próximo valor da grade de frequência.

A suíte tem 127 testes (64 Core, 11 DSP, 52 UI) com execução somada de aproximadamente
2,0 s; os testes de UI cobrem a estrutura do menu (ordem dos itens, seção "Microfone",
marcação da fonte selecionada, linha de fonte desconectada, atalhos ⌘, ⌘Q e "m"), as linhas
de view em AppKit (oito `NSSlider`, dois `NSSwitch`, dois `NSLevelIndicator` somente leitura
e sem foco), a altura do painel com e sem o selo do limitador, o valor de ganho e o valor de
frequência como rótulos, a grade de frequência (limites e arredondamento), o mapeamento
logarítmico posição ↔ Hz, o arrasto e as setas do slider de frequência e o passo de seta dos
sliders. `swift build`, `swift test`,
lint de formatação recursivo e a montagem debug passam. O arrasto no menu real, inclusive
soltando o mouse fora da janela do menu, a navegação por teclado e o clique nas linhas são
verificação manual pendente.

### Recuperação (etapa 5)

A lógica de recuperação está implementada e coberta pela HAL falsa; os itens que exigem
interação humana (notificações de suspensão, TCC, remoção do driver, reinício real do
`coreaudiod`) continuam pendentes no roteiro manual acima. A etapa 5 permanece em andamento.

Verificação automatizada: 127 testes (64 Core, 11 DSP, 52 UI) com execução somada de
aproximadamente 2,0 s; a suíte Core inclui o caso
negativo `fakeRejectsOutputWrite`, que registra uma issue conhecida intencionalmente.
`swift build`, `swift test`, lint recursivo de formatação, montagem debug e
`codesign --verify --strict` passam na máquina de referência.

Mudança de formato com hardware real (2026-11-03), C920 USB, buffer 256, `micboost-diag run`
e `micboost-diag set-rate`:

- a taxa de trabalho foi 24000 Hz nas duas pontas: o C920 oferece 16/24/32 kHz e o BlackHole
  não oferece 32 kHz, então a maior taxa comum abaixo de 48 kHz é 24 kHz;
- `starting` → `running` em 1111 ms; nenhuma reconstrução espúria depois do start;
- com o motor rodando, `set-rate` no BlackHole (44100, depois 48000) e no C920 (32000, depois
  16000) produziu `recovering(formatChanged)` → `running` em 432, 375, 1302 e 1193 ms, sempre
  de volta a 24000 Hz, com 0 overloads, `input_missing` e `nonfinite_resets`;
- o agregado privado fixa a taxa dos subdispositivos: o próprio `set-rate` lê a taxa antiga de
  volta (a HAL aceita e reverte a escrita), mas a notificação chega e o motor reconstrói. Uma
  mudança externa de taxa, portanto, não fica visível como uma taxa diferente; é a notificação
  que dispara a recuperação;
- a faixa de buffer e os safety offsets do dispositivo sobem quando o agregado entra em uso; essa
  mudança não é formato e não reconstrói o motor (teste `deviceLatencyChangeDoesNotRebuild`);
- no stop voluntário, as taxas voltaram a 16000 Hz (C920) e 16000 Hz (BlackHole), os valores
  anteriores à execução.

App com mudança de taxa (2026-11-03): painel aberto, processamento ligado, C920 selecionado,
ganho +6 dB e "Entrada do sistema: MicBoost". `set-rate` no BlackHole para 44100 com o app
rodando manteve a entrada padrão em `BlackHole2ch_UID` antes e depois, o rótulo de
acessibilidade do item de barra em "MicBoost, Ativo, 200% (+6,0dB)" e a linha de roteamento do
painel inalterada; o BlackHole voltou a 24000 Hz. Nenhum erro do motor restaurou a entrada
padrão. Sair pelo próprio app restaurou a entrada para `BuiltInMicrophoneDevice` e as taxas
para as anteriores. Estado final: BlackHole a 48000 Hz, C920 a 16000 Hz, entrada padrão
`BuiltInMicrophoneDevice` e nenhum processo `MicBoost.app` ou `micboost-diag` restante.

Capturas para o README: `docs/screenshots/eq-{light,dark}.png` e
`settings-{light,dark}.png` foram regeradas com estado de amostra realista (entrada do sistema
MicBoost com marcação, microfone USB com o selo de seleção, ganho +6 dB, medidores com níveis, 48000 Hz,
buffer 256 no seletor e no diagnóstico, latência reportada de 15,3 ms, switches nativos no
estado ativo e licença GPL-3.0). O locale vem do idioma resolvido pelo catálogo (`en` →
`en_US`), então os números usam ponto decimal e vírgula de milhar do inglês. `panel-*` e
`error-*` continuam geradas, mas não são mais referenciadas no README.

O menu deixou de ser uma view SwiftUI: as capturas `eq-*`, `panel-*` e `error-*` são do
`NSMenu` real, aberto pelo auxiliar e capturado com `SCScreenshotManager` (ScreenCaptureKit) a
partir do laço de tracking, com recorte na view de conteúdo do menu. A captura usa o menu
montado pelo `PanelMenuController` com o mesmo estado de exemplo, então mostra os itens
nativos, o selo da fonte selecionada, os atalhos ⌘, e ⌘Q e as insets medidas do menu. Os
itens de view alinham com o título dos itens nativos. `settings-*` continua vindo de
`NSHostingView.cacheDisplay`: não há menu a compor e os controles SwiftUI são AppKit por baixo.

Reteste do menu (2026-11-04): o medidor é exibição pura — `hitTest` devolve `nil`, `acceptsFirstResponder`
é falso e o `mouseDown` é inerte —, e o valor de ganho virou rótulo somente leitura, sem campo nem ação de
clique; o ganho continua pelo slider e pelas setas (0,5 dB, 1 dB com ⌥). As capturas `eq-*`, `panel-*` e
`error-*` foram regeradas sem anel de foco, porque o auxiliar solta o primeiro respondedor antes da captura.
`swift build`, `swift test` (127 testes) e
`swift format lint --strict` passam; o arrasto do medidor e o clique no valor de ganho no menu real ficam para
a verificação manual do mantenedor.

Restauração na saída (2026-11-04): a sequência manual que não restaurou a entrada padrão —
divergência em Ajustes do Sistema, "Usar MicBoost", divergência de novo, "Usar MicBoost", sair —
foi reproduzida na HAL falsa. Com a notificação de `kAudioHardwarePropertyDefaultInputDevice` da
mudança anterior ainda na fila `engine` quando a ação roda, a política lia a entrada antiga,
liberava `defaultInputManaged` recém-gravado e o stop não restaurava nada; o estado persistido
ficava igual ao observado no app (`previousDefaultInputUID` preenchido, `defaultInputManaged =
false`, entrada padrão ainda o BlackHole). Os testes `pendingDivergenceNotificationDoesNotDropTheAdoption`,
`quitAfterUseBlackHoleRestoresThePreviousInput`, `relaunchWithBlackHoleAlreadyDefaultKeepsThePersistedOwnership`
e `stopAndRestartRestoresOncePerVoluntaryStop` cobrem a sequência, e
`TerminationBarrierTests` cobre o portão de encerramento: a resposta a
`reply(toApplicationShouldTerminate:)` só vem depois do stop, um segundo ⌘Q não corta a
restauração e o prazo de 5 s encerra o app mesmo com o stop pendurado. Falta confirmar no app
com hardware real: divergir, usar MicBoost, divergir de novo, usar MicBoost e sair, com a
entrada anterior restaurada e `log show --last 5m --info --predicate 'subsystem ==
"io.github.vittau.MicBoost"'` mostrando as linhas da categoria `routing`.

Frequência do EQ em slider (2026-11-04): os campos de frequência do menu foram substituídos
por sliders `NSSlider` em escala logarítmica, com o valor em Hz como rótulo somente leitura,
alinhados aos sliders de ganho; a grade quantiza em 10/100/500/1000 Hz conforme a faixa e os
padrões 70, 3000 e 8000 Hz continuam na grade. `EQFrequencyScale` cobre a quantização nos
limites (195, 199, 200, 950, 999, 1000, 1240, 1250, 9750, 9999, 10000, 10400 e 14000 Hz), as
setas, o mapeamento logarítmico posição ↔ Hz e o máximo de 0,45 · fs; o arrasto e as setas do
slider da banda de médios são exercitados até o `AppModel`. `swift build`, `swift test` (127
testes, execução somada de ≈ 2,0 s) e `swift format lint --strict` passam, e as capturas
`eq-{light,dark}` foram regeradas e inspecionadas: os três sliders de frequência aparecem na
mesma coluna dos de ganho, com "70 Hz", "3000 Hz" e "8000 Hz" à direita. O arrasto real dentro
do menu aberto, soltando o mouse fora da janela, fica para a verificação manual do mantenedor.
