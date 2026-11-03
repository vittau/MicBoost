# Motor de áudio (Core Audio)

## Decisão: dispositivo agregado privado com um único IOProc

O motor cria um **dispositivo agregado privado** com dois subdispositivos: a fonte (dispositivo de clock principal) e o BlackHole 2ch (com compensação de drift). Um único IOProc C recebe a entrada da fonte e escreve a saída do BlackHole no mesmo ciclo.

Por quê:
- Não há fila entre callbacks: o processamento é in-place no ciclo de IO, e a latência adicional fica limitada a buffers e safety offsets dos dispositivos.
- A diferença entre os relógios da fonte e do BlackHole fica a cargo do resampler de drift do Core Audio. Assim a fila não cresce, sem buffer circular nem descarte e inserção de amostras.
- O agregado privado (`kAudioAggregateDeviceIsPrivateKey = 1`) não aparece para outros apps e morre com o processo.

Alternativa reservada (não implementar sem necessidade): ponte com dois IOProcs (fonte e BlackHole separados), buffer circular SPSC pré-alocado e resampler adaptativo controlado pelo nível do buffer. O agregado está adotado: no ensaio de estabilidade, a deriva de latência ficou em −0,06 ms ([testing.md](testing.md#resultados-registrados)). A alternativa só volta a ser considerada se uma fonte suportada (por exemplo, Bluetooth) não funcionar com o agregado; nesse caso, este documento é reescrito.

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
- sistema: `kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultInputDevice`;
- fonte e BlackHole ativos: `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyNominalSampleRate`, `kAudioDevicePropertyStreamConfiguration`;
- agregado: `kAudioDeviceProcessorOverload`, que incrementa o contador de overloads.

Mudanças chegam em rajadas. O controller agrupa eventos com 100 ms de coalescência antes de reconfigurar.

## Identificação do BlackHole

- Primária: UID `BlackHole2ch_UID` (UID padrão do build upstream de 2 canais, confirmado na máquina de referência).
- Alternativa: fabricante contendo "Existential Audio" e nome contendo "BlackHole", com exatamente 2 canais de saída.
- Qualquer dispositivo cujo UID ou nome comece com "BlackHole" é excluído como fonte, seja qual for a contagem de canais.
- Propriedades observadas no BlackHole 2ch instalado: fabricante "Existential Audio Inc.", transporte `virtual`, 2 canais de entrada e 2 de saída, taxas de 8 kHz a 768 kHz, latência e safety offset 0 nos dois escopos, buffer de 15 a 4096 frames.

## Construção do agregado

`AggregateBuilder` chama `AudioHardwareCreateAggregateDevice` com:

| Chave | Valor |
|---|---|
| `kAudioAggregateDeviceNameKey` | `"MicBoost Engine"` |
| `kAudioAggregateDeviceUIDKey` | `"io.github.vittau.MicBoost.engine"` |
| `kAudioAggregateDeviceIsPrivateKey` | `1` |
| `kAudioAggregateDeviceIsStackedKey` | `0` |
| `kAudioAggregateDeviceSubDeviceListKey` | `[{UID: fonte}, {UID: BlackHole, kAudioSubDeviceDriftCompensationKey: 1}]` (ordem fixa: fonte primeiro) |
| `kAudioAggregateDeviceMainSubDeviceKey` | UID da fonte |

Depois da criação, aguardar que o agregado apareça na lista de dispositivos e responda a `kAudioDevicePropertyDeviceIsAlive` (limite de 2 s). Se falhar, `error(.halFailure)`. Destruir com `AudioHardwareDestroyAggregateDevice` no stop. No launch, se existir um agregado com o UID acima (sobra de outra instância), destruí-lo antes de criar.

O adaptador valida formato virtual Float32 nativo e tenta configurar Float32 nos streams do agregado, preservando taxa e intercalação, antes de recusar um formato incompatível.

A qualidade do resampler de drift permanece no padrão do sistema (a chave de qualidade não é sobrescrita). Na webcam USB a 16 kHz, 18 minutos de correlação mostraram deriva de −0,0625 ms, sem overloads nem resets numéricos; a avaliação auditiva de artefatos permanece manual.

## Formato e taxa de amostragem

- **Nunca** alterar a taxa nominal da fonte.
- Se a taxa nominal do BlackHole for diferente da taxa da fonte e a taxa da fonte estiver em `AvailableNominalSampleRates` do BlackHole, definir a taxa do BlackHole igual à da fonte antes de criar o agregado. Isso afeta os consumidores do BlackHole, que se adaptam. Se não estiver disponível, `error(.formatUnsupported)`.
- O IOProc trabalha com o formato virtual dos streams do agregado. Exigir Float32 linear PCM nativo (`kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked`), intercalado ou não. Se o formato virtual não for Float32, tentar `kAudioStreamPropertyVirtualFormat` Float32 na mesma taxa. Se falhar, `error(.formatUnsupported)`.
- Uma mudança de taxa ou de configuração de streams, na fonte ou no BlackHole, com o motor em `running`, leva a `recovering` → reconstrução.

## Tamanho de buffer

- Definir `kAudioDevicePropertyBufferFrameSize` no agregado com `settings.bufferFrames` (padrão 256), limitado a `BufferFrameSizeRange`. O padrão é 256: a 16 kHz, a mediana de 38,875–38,9375 ms atende ao limite de 100 ms e esse buffer tem evidência de estabilidade. As opções são 64/128/256/512/1024 frames, sempre limitadas à faixa do agregado. A opção 64 atingiu mediana de 14,9375 ms a 16 kHz, mas não passou por ensaio prolongado. O tamanho continua expresso em frames: selecionar automaticamente ≈ 5,3 ms reduziria o buffer a 64 nessa fonte sem a mesma evidência de estabilidade.
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
| `auto` | 1 canal → mono duplicado; ≥ 2 canais → `mono(1)` | sempre, salvo escolha do usuário |
| `mono(n)` | canal *n* da fonte, duplicado em L/R do BlackHole | |
| `monoMix` | média dos canais 1…N, duplicada em L/R | |
| `stereo(n)` | canais *n* e *n+1* → L e R | só disponível com ≥ 2 canais |

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
4. Escrever L/R no BlackHole e zerar as demais saídas habilitadas.
5. Atualizar medidores e o contador de ciclos. Guardar `outTime->mHostTime - inTime->mHostTime` no atômico `io_delta_host` (diagnóstico).
6. Retornar `noErr` sempre.

## Latência reportada

`EngineController` calcula a latência reportada e a exibe no diagnóstico, somando:
- latência e safety offset de entrada da fonte (`kAudioDevicePropertyLatency` e `kAudioDevicePropertySafetyOffset`, escopo input), mais a latência do stream (`kAudioStreamPropertyLatency`);
- buffer do agregado;
- latência e safety offset de saída do BlackHole;
- a latência do agregado reportada pela HAL, quando disponível.

O valor oficial é o medido ([testing.md](testing.md#medição-de-latência)); o reportado serve só como referência.

## Política de entrada padrão (`DefaultInputManager`)

`DefaultInputManager` aplica a política sobre `AudioHardware` e `SettingsStore`, a partir de quatro chamadas feitas pelo `EngineController` na fila `engine` (ele não registra listeners):

- `engineDidStart(blackHole:)` ao entrar em `running`;
- `defaultInputDidChange()` quando `kAudioHardwarePropertyDefaultInputDevice` muda, devolvendo o `DefaultInputStatus` publicado;
- `useBlackHole()` para a ação "Usar BlackHole" da UI;
- `engineWillStop(reason:)` ao sair de `running`, com `reason` `user` (sair do app, desligar o processamento) ou `engineError`.

Ao entrar em `running`:
- Se a entrada padrão atual não for o BlackHole: gravar `previousDefaultInputUID` = UID atual e `defaultInputManaged = true` (gravação imediata) e então definir o BlackHole com `kAudioHardwarePropertyDefaultInputDevice`. A gravação vem antes da escrita na HAL, para que um crash no meio ainda restaure; se a escrita falhar, `defaultInputManaged` volta a `false`.
- Se já for o BlackHole: não alterar nada nem sobrescrever `previousDefaultInputUID`. Manter `defaultInputManaged` como estiver persistido, o que cobre a recuperação após crash.

Mudança externa da entrada padrão com o motor rodando: se a nova entrada não for o BlackHole, marcar `defaultInputManaged = false` e publicar `divergedByUser`. **Não** reverter. A ação "Usar BlackHole" repete o passo de entrada (salva o UID atual como anterior e define o BlackHole).

Ao parar (sair do app, desligar o processamento): restaurar `previousDefaultInputUID` somente se `defaultInputManaged == true`, a entrada atual for o BlackHole e o dispositivo anterior existir (e estiver vivo). Em seguida, limpar `defaultInputManaged`. Se o usuário trocou a entrada ou o dispositivo anterior sumiu, apenas limpar `defaultInputManaged`.

Erros do motor (`recovering`/`error`) **não** restauram a entrada padrão: `engineWillStop(reason: .engineError)` não escreve nada e mantém `defaultInputManaged`, para que o stop voluntário seguinte ainda restaure. O BlackHole fica em silêncio, e os apps consumidores não trocam de microfone de repente.

`DefaultInputStatus` tem três sinais: `isBlackHole` (a entrada padrão é o BlackHole 2ch), `divergedByUser` (o motor roda e a entrada não é o BlackHole) e `unknown` (o `DefaultInputManager` ainda não conhece o BlackHole, por exemplo antes do start, ou não conseguiu resolver a entrada atual).

Invariantes: nunca definir uma fonte física como padrão, exceto na restauração descrita acima; nunca tocar em `kAudioHardwarePropertyDefaultOutputDevice` nem em `kAudioHardwarePropertyDefaultSystemOutputDevice`.

## Recuperação

| Evento | Detecção | Ação |
|---|---|---|
| Fonte desconectada | `DeviceIsAlive` = 0 ou some de `Devices` | stop interno → `recovering(.sourceLost)`. Quando o mesmo UID voltar, reconstruir. Não trocar de fonte sozinho. |
| BlackHole removido | some de `Devices` | `error(.blackHoleMissing)`; sai ao reaparecer |
| Taxa/streams mudaram | listeners de formato | `recovering(.formatChanged)` → reconstruir |
| Suspensão/retomada | `NSWorkspace.willSleepNotification` / `didWakeNotification`, encaminhados pelo app ao controller | antes de dormir, stop com rampa; ao acordar, start com 1 s de atraso; se falhar, `recovering` |
| Permissão negada | `AVCaptureDevice.authorizationStatus(for: .audio)` antes do start e ao reativar o app | `error(.microphonePermissionDenied)` |
| Overload de IO | `kAudioDeviceProcessorOverload` | incrementar contador, sem mudar estado |
| Serviço de áudio reiniciado (`coreaudiod`) | todos os objetos inválidos / `Devices` muda por completo | descartar IDs em cache, reenumerar por UID e reconstruir |

Uma fonte que entrega apenas zeros mantém o motor em `running`; não há detecção automática de fonte silenciosa na v1.

Silêncio seguro: sempre que o processador não tiver entrada válida ou detectar não-finitos, a saída para o BlackHole é zero. Antes de qualquer stop voluntário, rampa de saída.
