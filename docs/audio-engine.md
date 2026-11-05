# Motor de áudio (Core Audio)

## Decisão: dispositivo agregado privado com um único IOProc

O motor cria um **dispositivo agregado privado** com dois subdispositivos: a fonte (com compensação de drift) e o BlackHole 2ch (dispositivo de clock principal). Um único IOProc C recebe a entrada da fonte e escreve a saída do BlackHole no mesmo ciclo.

Por quê:
- Não há fila entre callbacks: o processamento é in-place no ciclo de IO, e a latência adicional fica limitada a buffers e safety offsets dos dispositivos.
- A diferença entre os relógios da fonte e do BlackHole fica a cargo do resampler de drift do Core Audio. Assim a fila não cresce, sem buffer circular nem descarte e inserção de amostras.
- O BlackHole comanda o clock e o resampler fica na fonte, ou seja, antes do EQ, do ganho e do limitador. O limitador é o último estágio que toca a amostra: o BlackHole recebe exatamente o que `mb_engine_process` escreveu, e o teto de −1 dBFS medido na saída é o teto do limitador.
- Por que não o contrário: com o resampler no subdispositivo de saída, a interpolação entre amostras já limitadas ultrapassa o teto nos transientes. Medido com o microfone fifine a +24 dB e palmas: pico 1,1845 (+1,47 dBFS) e 118 amostras acima de −1 dBFS, com sinal alternando de signo a cada amostra. Uma sequência alternando ±0,891 tem pico interpolado maior que as próprias amostras, então nenhum limitador antes do resampler garante o teto na saída.
- O agregado privado (`kAudioAggregateDeviceIsPrivateKey = 1`) não aparece para outros apps e morre com o processo.

Alternativa reservada (não implementar sem necessidade): ponte com dois IOProcs (fonte e BlackHole separados), buffer circular SPSC pré-alocado e resampler adaptativo controlado pelo nível do buffer. O agregado está adotado: no ensaio de estabilidade do fifine a 48 kHz, a deriva de latência ficou em 0,0 ms em 20 minutos (15,2917 → 15,2917 ms; [testing.md](testing.md#resultados-registrados)). A alternativa só volta a ser considerada se uma fonte suportada (por exemplo, Bluetooth) não funcionar com o agregado; nesse caso, este documento é reescrito.

## Enumeração e elegibilidade

`DeviceService` lê `kAudioHardwarePropertyDevices` e, para cada dispositivo:
- UID: `kAudioDevicePropertyDeviceUID`;
- nome: `kAudioObjectPropertyName`;
- fabricante: `kAudioObjectPropertyManufacturer`;
- transporte: `kAudioDevicePropertyTransportType`;
- canais por escopo: soma de `kAudioDevicePropertyStreamConfiguration`;
- taxas: `kAudioDevicePropertyNominalSampleRate` e `kAudioDevicePropertyAvailableNominalSampleRates`;
- buffer: `kAudioDevicePropertyBufferFrameSizeRange`;
- se está vivo: `kAudioDevicePropertyDeviceIsAlive`.

Para agregados, a lista completa de UIDs (`kAudioAggregateDevicePropertyFullSubDeviceList`) é lida, incluindo membros inativos. A elegibilidade percorre agregados aninhados com proteção contra ciclos.

Uma fonte é elegível se tiver ≥ 1 canal de entrada, **não** for BlackHole (nenhuma variante), **não** for o agregado do próprio MicBoost e **não** for um agregado que contenha BlackHole.

Listeners (na fila `engine`):
- sistema: `kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyServiceRestarted`, `kAudioHardwarePropertyDefaultInputDevice`;
- fonte e BlackHole ativos: `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyNominalSampleRate`, `kAudioDevicePropertyStreamConfiguration`;
- agregado: `kAudioDeviceProcessorOverload`, que incrementa o contador de overloads.

Mudanças chegam em rajadas. O controller agrupa eventos com 100 ms de coalescência antes de reconfigurar. Eventos de formato (taxa e streams) nos 300 ms seguintes a um start são do próprio motor e são ignorados; notificações de taxa escritas pelo MicBoost também. Com uma fonte Bluetooth, a janela é de 3 s, e os eventos de formato da fonte durante o stop do próprio motor também são ignorados ([troca de perfil](#fonte-bluetooth-e-troca-de-perfil)). A comparação que decide reconstruir usa UID, ID, estado vivo, taxa e canais: faixa de buffer, latências e safety offsets mudam quando o agregado entra em uso e não são mudança de formato.

## Identificação do BlackHole

- Primária: UID `BlackHole2ch_UID` (UID padrão do build upstream de 2 canais, confirmado na máquina de referência).
- Alternativa: fabricante contendo "Existential Audio" e nome contendo "BlackHole", com exatamente 2 canais de saída.
- Qualquer dispositivo cujo UID ou nome comece com "BlackHole" é excluído como fonte, seja qual for a contagem de canais.
- Propriedades observadas no BlackHole 2ch instalado: fabricante "Existential Audio Inc.", transporte `virtual`, 2 canais de entrada e 2 de saída, taxas nominais 8000, 16000, 24000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600 e 768000 Hz (não anuncia 32000 Hz), latência e safety offset 0 nos dois escopos, buffer de 15 a 4096 frames.

## Fonte Bluetooth e troca de perfil

Quando um app abre o microfone de um fone Bluetooth, o macOS passa o fone do perfil de música (A2DP) para o de chamada (HFP). A taxa de entrada e de saída cai (tipicamente para 16 ou 24 kHz), as taxas disponíveis mudam e a configuração de streams é republicada, até alguns segundos depois do start. Ao soltar o microfone, o fone volta ao A2DP.

- A escolha da taxa de trabalho usa as taxas que a fonte anuncia no momento do start. Se a troca de perfil mudar a taxa depois do start, o motor faz **uma** reconstrução na taxa nova (`recovering(.formatChanged)`, sem faixa). A reconstrução conserva o descritor HFP observado antes do stop para escolher a taxa, mesmo que o próprio stop publique A2DP transitoriamente; listeners de formato de uma geração encerrada não provocam outra reconstrução.
- Para não entrar em laço (start → HFP → reconstrução → stop → A2DP → start…), a janela de eventos do próprio motor é de 3 s para fontes Bluetooth (transporte `bluetooth` ou `bluetoothLE`), e eventos de formato da fonte que chegam durante o stop do próprio motor são ignorados. Uma mudança de formato fora dessas janelas segue a regra normal.
- O mesmo fone como saída de monitor funciona: a AUHAL do monitor abre o lado de saída, já em HFP, na mesma taxa da fonte; a troca de perfil chega ao monitor como mudança de formato da saída e refaz só o monitor.
- Em HFP, o som dos fones fica com qualidade de chamada enquanto o MicBoost captura o microfone deles. É uma limitação do Bluetooth, documentada ao usuário em [product.md](product.md#público-e-dispositivos).

## Construção do agregado

`AggregateBuilder` chama `AudioHardwareCreateAggregateDevice` com:

| Chave | Valor |
|---|---|
| `kAudioAggregateDeviceNameKey` | `"MicBoost Engine"` |
| `kAudioAggregateDeviceUIDKey` | `"io.github.vittau.MicBoost.engine"` |
| `kAudioAggregateDeviceIsPrivateKey` | `1` |
| `kAudioAggregateDeviceIsStackedKey` | `0` |
| `kAudioAggregateDeviceSubDeviceListKey` | `[{UID: fonte, kAudioSubDeviceDriftCompensationKey: 1}, {UID: BlackHole}]` (ordem fixa: fonte primeiro) |
| `kAudioAggregateDeviceMainSubDeviceKey` | UID do BlackHole |

A lista de subdispositivos define a ordem dos streams do agregado (fonte, depois BlackHole); o subdispositivo principal define apenas o clock. Por isso a compensação de drift fica na fonte e a ordem da lista não muda em relação ao mapa de canais.

Depois da criação, aguardar que o agregado apareça na lista de dispositivos e responda a `kAudioDevicePropertyDeviceIsAlive` (limite de 2 s). Se falhar, `error(.halFailure)`. Destruir com `AudioHardwareDestroyAggregateDevice` no stop. No launch, se existir um agregado com o UID acima (sobra de outra instância), destruí-lo antes de criar.

O adaptador valida formato virtual Float32 nativo e tenta configurar Float32 nos streams do agregado, preservando taxa e intercalação, antes de recusar um formato incompatível.

A qualidade do resampler de drift permanece no padrão do sistema (a chave de qualidade não é sobrescrita). A compensação fica na fonte: o resampler recebe o sinal cru do microfone e entrega amostras na taxa do BlackHole antes do EQ, do ganho e do limitador. A avaliação auditiva de artefatos permanece manual; a deriva de latência medida nos ensaios de estabilidade fica em [testing.md](testing.md#resultados-registrados).

## Formato e taxa de amostragem

- **Taxa de trabalho:** a cada start (inclusive ao trocar de fonte e ao reconstruir após recuperação), escolher entre as taxas suportadas pela fonte e pelo BlackHole: 48 kHz, se houver; senão, a maior taxa abaixo de 48 kHz; senão, a menor acima de 48 kHz. Taxas acima de 48 kHz não trazem ganho para voz e só aumentam CPU, por isso 48 kHz é o teto preferido. Se não houver taxa em comum, `error(.formatUnsupported)`.
- Antes de criar o agregado, definir a taxa nominal da fonte e a do BlackHole com a taxa de trabalho, quando forem diferentes. Mudar a taxa da fonte afeta outros apps que a leem diretamente, que se adaptam. Dispositivos cuja taxa é imposta pelo próprio perfil (por exemplo, Bluetooth em HFP) simplesmente não oferecem outras taxas.
- **Restauração:** ao parar voluntariamente (sair, desligar o processamento, trocar de fonte), devolver a taxa anterior de cada dispositivo que o MicBoost alterou, somente se a taxa atual ainda for a que o MicBoost definiu e o dispositivo existir. Erros do motor não restauram. As taxas anteriores ficam em memória durante a sessão, indexadas por UID; após um crash, não há restauração. A restauração acontece depois de destruir o agregado e é melhor esforço: uma falha nela não impede o stop.
- Mudanças de taxa feitas pelo próprio MicBoost não contam como mudança externa de formato. A HAL pode recusar ou reverter uma taxa imposta de fora enquanto o agregado privado está em uso; a notificação que chega mesmo assim leva a `recovering(.formatChanged)` e o motor reaplica a taxa de trabalho.
- O IOProc trabalha com o formato virtual dos streams do agregado. Exigir Float32 linear PCM nativo (`kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked`), intercalado ou não. Se o formato virtual não for Float32, tentar `kAudioStreamPropertyVirtualFormat` Float32 na mesma taxa. Se falhar, `error(.formatUnsupported)`.
- Uma mudança de taxa ou de configuração de streams, na fonte ou no BlackHole, com o motor em `running`, leva a `recovering` → reconstrução.

## Tamanho de buffer

- Definir `kAudioDevicePropertyBufferFrameSize` no agregado com `settings.bufferFrames` (padrão 256), limitado a `BufferFrameSizeRange`. Opções: 64/128/256/512/1024 frames. O padrão 256 tem ensaio de estabilidade aprovado no fifine a 48 kHz, medindo 15,3 ms, e o buffer de 64 mede 7,3 ms, dentro dos 100 ms da v1 ([testing.md](testing.md#resultados-registrados)). O tamanho é expresso em frames, então a duração do buffer depende da taxa da fonte.
- `mb_engine_create` recebe o máximo de frames por ciclo, igual a `kAudioDevicePropertyBufferFrameSize` ou a `kAudioDevicePropertyUsesVariableBufferFrameSizes`, quando presente, para pré-alocar os buffers de trabalho. Se um ciclo chegar com mais frames do que o máximo, o processador trabalha em blocos internos desse tamanho.

## Mapa de streams e canais

O buffer de entrada do agregado contém os streams de entrada de cada subdispositivo, na ordem da lista (fonte, depois BlackHole). O de saída contém os streams de saída na mesma ordem (por exemplo, a saída de um headset USB antes do BlackHole).

- O `AggregateBuilder` calcula o mapa a partir de `StreamConfiguration` de cada subdispositivo: índices de buffer e canal dos canais de entrada da fonte e dos dois canais de saída do BlackHole.
- Desativar os streams não usados com `kAudioDevicePropertyIOProcStreamUsage` (entradas do BlackHole e saídas da fonte). O IOProc tolera `mData == NULL` e escreve zeros em qualquer buffer de saída habilitado que não seja do BlackHole.
- O mapa é imutável enquanto o IOProc roda e é passado a `mb_engine_configure` antes do start.

### Canais

O modo de canais é escolhido por dispositivo (`channelSelectionByUID`) e muda em tempo real (atômico, sem reiniciar):

| Modo | Comportamento | Padrão quando |
|---|---|---|
| `mono(n)` | canal *n* da fonte, duplicado em L/R do BlackHole | `mono(1)` é o padrão |
| `monoMix` | média dos canais 1…N, duplicada em L/R | |
| `stereo(n)` | canais *n* e *n+1* → L e R | só disponível com ≥ 2 canais |

O modo `auto` é aceito pela API para compatibilidade e equivale a `mono(1)`;
settings persistidos com esse modo são normalizados para `mono(1)` na leitura.
A UI oferece Mono 1, Mono 2 e demais canais mono, Misturar e Estéreo, nessa ordem.

Em modo mono, o processador roda um único canal e copia o resultado para L e R. Em estéreo, roda dois canais com o limitador ligado (mesmo ganho de redução nos dois).

## IOProc

```c
OSStatus mb_ioproc(AudioObjectID dev, const AudioTimeStamp *now,
                   const AudioBufferList *in, const AudioTimeStamp *inTime,
                   AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx);
```

Por ciclo:
1. Ler alvos atômicos (ganho, mute, EQ, bypass, modo de canais, fade-out).
2. Extrair os canais da fonte segundo o mapa para os buffers de trabalho pré-alocados. Se a entrada não vier (buffer nulo, tamanho zero), usar silêncio e incrementar `input_missing`.
3. Rodar a cadeia DSP ([dsp.md](dsp.md)).
4. Escrever L/R no BlackHole e zerar as demais saídas habilitadas. Com `monitor_enabled`, copiar as mesmas amostras L/R para a fila do [monitor](#fila-e-conversão-tempo-real).
5. Atualizar medidores e o contador de ciclos. Guardar `outTime->mHostTime - inTime->mHostTime` no atômico `io_delta_host` (diagnóstico).
6. Retornar `noErr` sempre.

## Latência reportada

`EngineController` calcula a latência reportada e a exibe no diagnóstico, somando:
- latência e safety offset de entrada da fonte (`kAudioDevicePropertyLatency` e `kAudioDevicePropertySafetyOffset`, escopo input), mais a latência do stream (`kAudioStreamPropertyLatency`);
- buffer do agregado;
- latência e safety offset de saída do BlackHole;
- a latência do agregado reportada pela HAL, quando disponível.

O valor oficial é o medido ([testing.md](testing.md#medição-de-latência)); o reportado serve só como referência.

## Modo monitor

Com o monitor ligado, a voz processada sai também na saída padrão do sistema, para o usuário ouvir a si mesmo. A meta é latência **adicionada pelo MicBoost < 20 ms** (mediana no buffer 256 a 48 kHz), medida pelo próprio motor ([Latência do monitor](#latência-do-monitor)). Latências físicas de entrada e saída não entram na meta.

**Decisão: o monitor é um caminho separado, com a conversão de taxa do sistema.** O agregado continua com apenas a fonte e o BlackHole. O IOProc do motor copia as amostras finais para uma fila SPSC. Na saída de monitor roda uma unidade de saída AUHAL (`kAudioUnitSubType_HALOutput`) com o formato do cliente na taxa do motor; o próprio AUHAL converte para a taxa nominal da saída. Antes dela, uma unidade `kAudioUnitSubType_Varispeed` do sistema corrige o drift entre os relógios, com a velocidade ajustada pela ocupação da fila. Assim o monitor funciona com qualquer combinação de taxas (por exemplo, fonte a 48 kHz e fone Bluetooth a 44,1 kHz), ligar e desligar não interrompe o áudio entregue aos apps, e nenhuma falha da saída afeta o BlackHole. O custo é a ocupação da fila e a latência das unidades de conversão, somadas à latência do monitor. Não há conversor de taxa próprio nem biblioteca externa.

- **Saída de monitor:** o dispositivo de `kAudioHardwarePropertyDefaultOutputDevice`, apenas lido. O MicBoost nunca escreve a saída padrão (nem `kAudioHardwarePropertyDefaultSystemOutputDevice`) e **nunca altera a taxa nominal da saída**: o monitor usa a taxa em que ela está.
- **Elegível** se tiver ≥ 1 canal de saída, **não** for BlackHole (nenhuma variante), **não** for o agregado do MicBoost e **não** for um agregado que contenha BlackHole (mesma verificação recursiva da fonte). Escrever no BlackHole seria realimentação. Uma saída que é o próprio dispositivo da fonte (headset USB ou Bluetooth com entrada e saída) é elegível: a AUHAL do monitor é um cliente a mais do dispositivo, fora do agregado.
- **Formato:** o AUHAL converte do formato do cliente para o formato da saída; se a AUHAL recusar o formato ou a inicialização, o monitor fica indisponível (`formatUnsupported` ou `startFailed`).
- **Canais:** as mesmas amostras de L e R do BlackHole vão para os canais 1 e 2 da saída; com uma saída de um canal, vai `(L + R) / 2`; demais canais recebem zero.
- **Sinal:** é o que o BlackHole recebe (depois de EQ, ganho, mute e limitador). Mute e fade-out silenciam também o monitor. Não há volume próprio: o volume da saída do sistema controla o monitor.

### Fila e conversão (tempo real)

- **Fila:** buffer circular SPSC estéreo de Float32, pré-alocado em `mb_engine_create` com capacidade fixa de 8192 frames na taxa do motor. O IOProc do motor escreve só enquanto o atômico `monitor_enabled` estiver ligado; índices de leitura e escrita são atômicos com ordem acquire/release. Cada bloco escrito leva o `mHostTime` do instante de entrada (`inInputTime`) do seu primeiro frame, para a medição de latência.
- **Cadeia do sistema:** AUHAL na saída de monitor (`kAudioOutputUnitProperty_CurrentDevice`, entrada desabilitada, saída habilitada), com formato do cliente Float32 não intercalado, 2 canais, na taxa do motor; o AUHAL converte a taxa e leva L e R aos canais 1 e 2 da saída (`kAudioOutputUnitProperty_ChannelMap`); com uma saída de um canal, o formato do cliente é mono e o callback entrega `(L + R) / 2`. O AUHAL puxa da Varispeed; a Varispeed puxa do callback de render em C, que lê a fila. Unidades criadas, configuradas e inicializadas na fila `engine`; `AudioOutputUnitStart`/`Stop` também.
- **Callback de render:** função C (`mb_monitor_render`) com contexto `mb_monitor`, criado na fila `engine` antes de iniciar a AUHAL e liberado só depois de `AudioOutputUnitStop` e `AudioUnitUninitialize`. A fila tem posse compartilhada entre motor e contexto do monitor; se a limpeza das unidades falhar, o contexto e a fila permanecem válidos para uma nova tentativa, sem impedir a reconstrução do motor. Segue as regras do IOProc: só C, sem alocação, locks, logs ou HAL. Escreve silêncio e incrementa `monitor_underruns` quando a fila não tem frames suficientes; aplica fade-in de 10 ms ao iniciar e fade-out de 10 ms antes de parar; com o atômico de diagnóstico silencioso, entrega zeros sem alterar ocupação nem timing.
- **Controle de ocupação:** alvo = buffer do motor + maior pull observado (frames na taxa do motor) + 1 ms. Começa com o buffer IO lido da AUHAL, convertido para frames do motor; o maior pull desde o início só aumenta o alvo, limitado à capacidade de 8192 frames. O pico por janela de leitura é outro atômico, zerado ao ler, sem apagar esse histórico de adaptação. Um PI lento, na fila `engine` a 20 Hz, corrige a Varispeed em até ±0,5%. Fila cheia descarta os frames mais antigos e incrementa `monitor_overruns_full`; reinício de ocupação incrementa apenas `monitor_resets`. Um reinício exige excursão de pelo menos o alvo e de mais de metade da capacidade, evitando confundir uma rajada normal com falha. Faltas continuam em `monitor_underruns`. A partida preenche o alvo com silêncio.
- **Buffer IO da saída:** somente leitura, pela AUHAL (`AudioUnitGetProperty`, `kAudioDevicePropertyBufferFrameSize`, escopo output); se a consulta falhar, mantém o último valor/dispositivo e identifica o fallback no relatório. Não há escrita de buffer pela AUHAL nem pela HAL física. O tamanho preferido mostrado é apenas a duração do buffer do motor convertida à taxa da saída e limitada à faixa informada, não uma requisição nem garantia de aceitação. Requisitar um buffer isolado por cliente é questão em aberto até verificar o isolamento entre apps; a [QA1533 da Apple](https://developer.apple.com/library/archive/qa/qa1533/_index.html) descreve o buffer de hardware e o limite de renderização, sem fornecer essa garantia.
- **Qualidade:** a do conversor do sistema na configuração padrão do AUHAL; verificada nos testes offline da cadeia ([testing.md](testing.md#fila-e-conversão-do-monitor-micboostcoretests)).

### Ciclo de vida

- **Ligar e desligar** o monitor inicia ou para só a cadeia do monitor; o motor e o agregado não são reconstruídos e o áudio dos apps não é interrompido. `EngineController.setMonitorEnabled(_:)` guarda o desejo em memória e só inicia o monitor com o motor em `running`; com o motor parado ou em erro, o desejo vale para o próximo start.
- **Estado em memória:** o monitor começa desligado a cada abertura do app (não é persistido), para não tocar a voz nos alto-falantes sem o usuário pedir.
- **Mudanças:** com o monitor ligado, o controller observa `kAudioHardwarePropertyDefaultOutputDevice` e, na saída de monitor, `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyNominalSampleRate` e `kAudioDevicePropertyStreamConfiguration`, com coalescência de 100 ms. Saída padrão trocada, saída removida ou com formato alterado → só o caminho do monitor é refeito, com a saída padrão atual. Uma reconstrução do motor (troca de fonte, buffer, recuperação, wake) para o monitor antes e o reinicia depois.
- **Falhas:** qualquer falha do monitor (HAL, formato) deixa o monitor indisponível, é registrada no log `engine` com a operação, o `OSStatus` e a saída, e nunca muda o estado do motor nem mostra faixa.

`MonitorStatus` (em `EngineStatus.monitor`): `off` (desligado ou motor parado), `active(output: AudioDevice, addedLatencyMs: Double?, totalLatencyMs: Double)` ou `unavailable(reason, outputName: String?)`, com `reason` `noOutput` (sem saída padrão ou sem canais de saída), `outputIsLoopback` (BlackHole, agregado com BlackHole ou o agregado do MicBoost), `formatUnsupported` e `startFailed`.

### Latência do monitor

- **Latência adicionada (medida):** o callback de render calcula, para o primeiro frame entregue em cada ciclo, o `mHostTime` do timestamp do render − o `mHostTime` de entrada daquele frame no IOProc do motor, e guarda no atômico `monitor_latency_host` (média móvel). O controller soma somente a latência de processamento das unidades (`kAudioUnitProperty_Latency` da Varispeed e da AUHAL); não soma outro buffer de saída. A Apple define o timestamp de render como o tempo HAL em que os dados serão renderizados ([AURenderObserver](https://developer.apple.com/documentation/audiotoolbox/aurenderobserver)) e `inOutputTime` como o instante de entrega do primeiro frame ao hardware ([AudioDeviceIOProc](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc)); portanto é um horário programado, não o instante atual do callback, e adicionar um buffer completo outra vez duplica esse adiantamento. Não se presume que o adiantamento seja exatamente um buffer em todos os dispositivos. `micboost-diag` e o diagnóstico dos ajustes mostram o resultado. É a meta de < 20 ms. Inclui o ciclo do motor, a fila, a conversão e o ciclo da saída, mas não a latência física da fonte nem a da saída.
- **Latência total estimada:** latência, safety offset e latência de stream de entrada da fonte + latência adicionada + latência, safety offset e latência de stream de saída da saída de monitor. É o "≈ N ms" do painel, com "atraso alto" acima de 50 ms. Em saídas Bluetooth, a latência física do fone costuma passar de 100 ms.
- O diagnóstico tem um atômico de monitor silencioso, definido antes do start do monitor: fila, conversão e timing idênticos, mas a saída recebe zero. O app nunca ativa esse modo.

## Política de entrada padrão (`DefaultInputManager`)

`DefaultInputManager` aplica a política sobre `AudioHardware` e `SettingsStore`, a partir de quatro chamadas feitas pelo `EngineController` na fila `engine` (ele não registra listeners):

- `engineDidStart(blackHole:)` ao entrar em `running`;
- `defaultInputDidChange()` quando `kAudioHardwarePropertyDefaultInputDevice` muda, devolvendo o `DefaultInputStatus` publicado;
- `useBlackHole()` para a ação "Usar BlackHole" da UI;
- `engineWillStop(reason:)` ao sair de `running`, com `reason` `user` (sair do app, desligar o processamento) ou `engineError`.

A política automática só vale com `manageDefaultInput = true` (padrão). Com `false`, o `DefaultInputManager` não escreve a entrada padrão em nenhum momento: não assume o BlackHole ao iniciar e não restaura ao parar. Ele continua publicando o `DefaultInputStatus`, e a ação manual "Usar BlackHole" continua disponível, mas sem restauração posterior. Ao desligar a opção com `defaultInputManaged = true`, a entrada atual é mantida e `defaultInputManaged` é limpo.

Ao entrar em `running`:
- Se a entrada padrão atual não for o BlackHole: gravar `previousDefaultInputUID` = UID atual e `defaultInputManaged = true` (gravação imediata) e então definir o BlackHole com `kAudioHardwarePropertyDefaultInputDevice`. A gravação vem antes da escrita na HAL, para que um crash no meio ainda restaure; se a escrita falhar, `defaultInputManaged` volta a `false`.
- Se já for o BlackHole: não alterar nada nem sobrescrever `previousDefaultInputUID`. Manter `defaultInputManaged` como estiver persistido, o que cobre a recuperação após crash.
- Enquanto a adoção está em andamento — entre a gravação e a escrita na HAL — a notificação de `kAudioHardwarePropertyDefaultInputDevice` que ainda leia a entrada anterior **não** é divergência do usuário: ela não libera `defaultInputManaged` e só publica o `DefaultInputStatus`. Sem isso, a notificação atrasada da própria troca que o usuário está desfazendo apagaria a posse recém-gravada, e o stop voluntário seguinte não restauraria nada.

Mudança externa da entrada padrão com o motor rodando: se a nova entrada não for o BlackHole, marcar `defaultInputManaged = false` e publicar `divergedByUser`. **Não** reverter. A ação "Usar BlackHole" repete o passo de entrada (salva o UID atual como anterior e define o BlackHole).

Ao parar (sair do app, desligar o processamento): restaurar `previousDefaultInputUID` somente se `defaultInputManaged == true`, a entrada atual for o BlackHole e o dispositivo anterior existir (e estiver vivo). Em seguida, limpar `defaultInputManaged`. Se o usuário trocou a entrada ou o dispositivo anterior sumiu, apenas limpar `defaultInputManaged`. A política considera o motor fora de `running` antes do primeiro `await` do stop, então uma notificação de entrada padrão processada durante a restauração não libera a posse no meio dela.

Erros do motor (`recovering`/`error`) **não** restauram a entrada padrão: `engineWillStop(reason: .engineError)` não escreve nada e mantém `defaultInputManaged`, para que o stop voluntário seguinte ainda restaure. O BlackHole fica em silêncio, e os apps consumidores não trocam de microfone de repente.

`DefaultInputStatus` tem três sinais: `isBlackHole` (a entrada padrão é o BlackHole 2ch), `divergedByUser` (o motor roda e a entrada não é o BlackHole) e `unknown` (o `DefaultInputManager` ainda não conhece o BlackHole, por exemplo antes do start, ou não conseguiu resolver a entrada atual).

Invariantes: nunca definir uma fonte física como padrão, exceto na restauração descrita acima; nunca escrever `kAudioHardwarePropertyDefaultOutputDevice` nem `kAudioHardwarePropertyDefaultSystemOutputDevice` (o [modo monitor](#modo-monitor) só lê a saída padrão).

## Recuperação

`EngineState.recovering` carrega o motivo: `sourceLost`, `formatChanged`, `serviceRestarted`, `sleep` ou `wakeFailed`. O app usa o motivo para decidir a mensagem ([ui.md](ui.md#mensagens-de-estado)).

| Evento | Detecção | Ação |
|---|---|---|
| Fonte desconectada | `DeviceIsAlive` = 0 ou some de `Devices` | stop interno com rampa → `recovering(.sourceLost)`. Quando o mesmo UID voltar, reconstruir. Não trocar de fonte sozinho. |
| BlackHole removido | some de `Devices` ou `DeviceIsAlive` = 0 | `error(.blackHoleMissing)`; destrói o agregado. Sai ao reaparecer, com uma reconstrução. |
| Taxa/streams mudaram | listeners de formato na fonte e no BlackHole | `recovering(.formatChanged)` → reconstruir e reaplicar a taxa de trabalho. |
| Suspensão/retomada | `NSWorkspace.willSleepNotification` / `didWakeNotification`, encaminhados pelo app ao controller | antes de dormir, stop com rampa em `recovering(.sleep)`; ao acordar, uma única tentativa de start 1 s depois. Falha de HAL ou formato na tentativa → `recovering(.wakeFailed)`; dispositivo ausente ou permissão negada mantêm o `error` correspondente. |
| Permissão negada | `AVCaptureDevice.authorizationStatus(for: .audio)` antes do start e quando o app volta a ficar ativo | `error(.microphonePermissionDenied)`; concedida a permissão, o app tenta iniciar de novo. |
| Overload de IO | `kAudioDeviceProcessorOverload` | incrementar contador, sem mudar estado. |
| Serviço de áudio reiniciado (`coreaudiod`) | `kAudioHardwarePropertyServiceRestarted` (e `Devices` mudando por completo) | `recovering(.serviceRestarted)`: descartar IDs em cache, reenumerar por UID e reconstruir. |

Em `recovering` e nos `error` de dispositivo não há polling: a próxima mudança em `Devices` (ou no formato) tenta de novo. A única exceção é a tentativa única depois do wake. Erros do motor nunca restauram a entrada padrão nem as taxas dos dispositivos: um stop voluntário posterior ainda restaura.

Uma fonte que entrega apenas zeros mantém o motor em `running`; não há detecção automática de fonte silenciosa na v1.

Silêncio seguro: sempre que o processador não tiver entrada válida ou detectar não-finitos, a saída para o BlackHole é zero. Antes de qualquer stop voluntário, rampa de saída.

A enumeração tolera `kAudioHardwareBadObjectError` por dispositivo: um objeto pode
sumir entre a leitura da lista de IDs e suas propriedades, inclusive logo após destruir
um agregado. Outros erros continuam sendo propagados como `EngineError.halFailure`.
Listeners do agregado são removidos antes de destruí-lo, preservando a ordem de teardown.
