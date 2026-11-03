# Arquitetura

## Visão geral

```text
┌──────────────────────── MicBoostApp (main thread) ────────────────────────┐
│ AppKit: NSStatusItem + MenuBarPanel (NSPanel)  ·  SwiftUI: PanelView,     │
│ SettingsView  ·  @Observable AppModel  ·  MeterPoller (20 Hz, só visível) │
└───────────────┬───────────────────────────────────────────▲───────────────┘
                │ comandos async                            │ snapshots de estado
┌───────────────▼──────────── MicBoostCore (EngineController) ──────────────┐
│ actor em DispatchSerialQueue "engine": DeviceService (listeners HAL),     │
│ DefaultInputManager, AggregateBuilder, máquina de estados, SettingsStore  │
└───────────────┬───────────────────────────────────────────▲───────────────┘
                │ setters atômicos (C)                      │ leituras atômicas (medidores/contadores)
┌───────────────▼──────────── MicBoostDSP (C, tempo real) ──────────────────┐
│ mb_ioproc → mapa de canais → EQ → ganho → limitador → BlackHole           │
└───────────────────────────────────────────────────────────────────────────┘
```

## Pacote Swift

O projeto é um único pacote SwiftPM (sem `.xcodeproj`). O `.app` é montado por script ([distribution.md](distribution.md#build)).

- `swift-tools-version: 6.0`, modo de linguagem Swift 6 (concorrência estrita), `platforms: [.macOS(.v14)]`.
- Toolchain de referência: Xcode 27.2 / Swift 6.4.

| Target | Tipo | Responsabilidade |
|---|---|---|
| `MicBoostDSP` | C (C17) | Tudo que roda na thread de IO: `mb_ioproc`, processador, biquads, ganho, limitador, medidores e parâmetros atômicos. Sem dependências além de `<CoreAudio/CoreAudioTypes.h>`, `<stdatomic.h>` e `<math.h>`. |
| `MicBoostCore` | Swift library | Abstração da HAL (`AudioHardware` protocol + implementação real), `DeviceService`, `AggregateBuilder`, `EngineController`, `DefaultInputManager`, `SettingsStore`, modelos de domínio e permissão de microfone. Sem AppKit/SwiftUI. |
| `MicBoostApp` | Swift executable (produto `MicBoost`) | Ciclo de vida do app, item de status, painel, ajustes, mensagens. Depende de `MicBoostCore`. |
| `micboost-diag` | Swift executable | CLI de diagnóstico e medição ([testing.md](testing.md#ferramenta-de-diagnóstico)). Depende de `MicBoostCore`. |
| `MicBoostDSPTests` | Swift Testing | Testes offline do processador via API C. |
| `MicBoostCoreTests` | Swift Testing | Política de entrada padrão, máquina de estados, settings e mapa de canais, com HAL falsa. |

`AudioHardware` expõe `devices()`, leitura/escrita da entrada padrão e registro/remoção de listeners por `HardwareProperty` em uma `DispatchQueue`. Não há operação de escrita da saída padrão no protocolo. `CoreAudioHardware` converte todos os status em `EngineError.halFailure`. `FakeAudioHardware` fica em `Tests/MicBoostCoreTests`; seu ponto de escrita de propriedades padrão registra uma falha de Swift Testing ao receber a saída padrão.

Estrutura de diretórios:

```text
Package.swift
Sources/MicBoostDSP/{include/MicBoostDSP.h, *.c}
Sources/MicBoostCore/{HAL/, Devices/, Engine/, Routing/, Settings/, Permissions/}
Sources/MicBoostApp/{App/, StatusItem/, Panel/, Settings/, Localization/}
Sources/micboost-diag/
Tests/MicBoostDSPTests/  Tests/MicBoostCoreTests/
Resources/{Info.plist, AppIcon.icns}
scripts/{build-app.sh, package-release.sh}
packaging/homebrew/micboost.rb      # modelo do cask publicado no tap
docs/
```

Frameworks linkados: CoreAudio, AudioToolbox, AVFoundation (só para `AVCaptureDevice.authorizationStatus/requestAccess`), AppKit, SwiftUI.

## Threads e regras de concorrência

| Contexto | Quem | Pode | Não pode |
|---|---|---|---|
| Main actor | UI, `AppModel` | SwiftUI/AppKit, chamar o `EngineController` com `await` | Chamar a HAL diretamente ou bloquear |
| Fila `engine` | `EngineController` (actor cujo `unownedExecutor` é uma `DispatchSerialQueue`), listeners HAL | Chamadas HAL que bloqueiam (criar agregado, start/stop), persistência | Tocar UI |
| Thread de IO do Core Audio | `mb_ioproc` (C) | Ler parâmetros atômicos, processar, escrever medidores atômicos | Alocar, liberar, travar locks, acessar disco, logar, chamar Swift/Objective-C, chamar a HAL |

- Os listeners HAL usam `AudioObjectAddPropertyListenerBlock` com a fila `engine`, de modo que todas as mudanças de dispositivo ficam serializadas fora dos callbacks de áudio.
- O IOProc é uma função C registrada com `AudioDeviceCreateIOProcID`. O contexto é um `mb_engine *` alocado pelo Swift na fila `engine`, antes do start, e liberado só depois de `AudioDeviceStop` + `AudioDeviceDestroyIOProcID`.
- Parâmetros (Swift → C): o lado de controle escreve alvos em `_Atomic float`/`_Atomic int` com ordem relaxed; o IOProc lê uma vez por bloco. Combinações momentaneamente inconsistentes entre parâmetros são aceitáveis, porque todos passam por suavização.
- Medidores (C → Swift): o IOProc mantém picos máximos em atômicos, e o lado de controle lê e zera com `atomic_exchange` (pico desde a última leitura). Contadores (`uint64`) são monotônicos.
- Logs: `os.Logger` (subsystem `io.github.vittau.MicBoost`) apenas fora da thread de IO. Eventos de IO (NaN, entrada ausente) viram contadores lidos depois.

`DeviceService` recebe uma fila serial e um callback de `Result<DeviceSnapshot, Error>`. `start`, `stop` e `snapshot` são chamados nessa fila; `stop` remove listeners antes de liberar o serviço. A fila confina também o adaptador HAL. Observa sistema e propriedades dos dispositivos enumerados; reenumera após 100 ms sem novos eventos. O snapshot contém todos os dispositivos, fontes elegíveis, BlackHole detectado e UID da entrada padrão. O adaptador real deve ter um único dono nessa fila.

## Ciclo de vida do motor

Estados (`EngineState`): `stopped`, `starting`, `running`, `recovering(reason)`, `error(EngineError)`.

```text
stopped ──start──▶ starting ──ok──▶ running
   ▲                  │ falha          │ fonte sumiu / formato mudou / wake
   │                  ▼                ▼
   └──stop──── error(…) ◀──falha── recovering ──fonte de volta / reconfig ok──▶ starting
```

- `EngineError`: `blackHoleMissing`, `microphonePermissionDenied`, `sourceUnavailable(uid)`, `noSourceSelected`, `formatUnsupported`, `halFailure(OSStatus, operation)`.
- `start` verifica, nesta ordem: permissão de microfone → BlackHole presente → fonte presente → constrói o agregado → configura formato/buffer → cria o IOProc → `AudioDeviceStart` → aplica a política de entrada padrão.
- Em `recovering`, o controller observa a lista de dispositivos e tenta de novo quando a condição muda. Não há polling. Exceção: depois do wake, uma única tentativa com atraso de 1 s.
- `error(.blackHoleMissing)` e `error(.sourceUnavailable)` saem sozinhos quando o dispositivo aparece. `microphonePermissionDenied` é reavaliado quando o app volta a ficar ativo.
- `stop` faz uma rampa de saída para zero (≤ 10 ms, via flag atômica de fade-out e espera de 2 ciclos de IO, com limite de 50 ms), `AudioDeviceStop`, destrói o IOProc, destrói o agregado e restaura a entrada padrão conforme a política.
- Ganho, mute, EQ, bypass e modo de canais **nunca** reiniciam o motor. Mudar a fonte ou o tamanho de buffer reconstrói o motor (stop → start), com rampa.

## Modelo de domínio (MicBoostCore)

- `AudioDevice`: `id: AudioObjectID`, `uid: String`, `name: String`, `manufacturer`, `transport` (builtIn, usb, bluetooth, bluetoothLE, aggregate, virtual, continuity/unknown…), `inputChannels`, `outputChannels`, `nominalSampleRate`, `availableSampleRates`, `bufferFrameSizeRange`, `isAlive`.
- `DeviceService` publica `[AudioDevice]` de entrada elegíveis (ver exclusões em [audio-engine.md](audio-engine.md#enumeração-e-elegibilidade)), o BlackHole detectado (se houver) e o UID da entrada padrão atual.
- `EngineStatus` (snapshot enviado à UI): `state`, `source: AudioDevice?`, `blackHole: AudioDevice?`, `defaultInput: DefaultInputStatus` (`isBlackHole`, `divergedByUser`, `unknown`), `sampleRate`, `bufferFrames`, `reportedLatencyMs`, contadores (overloads, eventos NaN).

## Persistência

`SettingsStore` grava um struct `Settings: Codable` versionado (`schemaVersion`) em `UserDefaults` (suite padrão do bundle), com debounce de 300 ms para não gravar a cada movimento do slider.

| Campo | Padrão | Notas |
|---|---|---|
| `processingEnabled` | `true` | Liga/desliga o motor ao abrir o app |
| `selectedInputUID` | `nil` | Primeira execução: entrada padrão atual, se elegível; senão, a primeira elegível |
| `gainDB` | `0` | Faixa em [dsp.md](dsp.md#ganho) |
| `muted` | `false` | |
| `eq` | ver [dsp.md](dsp.md#equalizador) | `enabled`, `low{freq, gainDB}`, `mid{freq, gainDB, q}`, `high{freq, gainDB}` |
| `channelSelectionByUID` | `[:]` | Modo de canais por dispositivo ([audio-engine.md](audio-engine.md#canais)) |
| `bufferFrames` | `256` | Opções 128/256/512/1024, limitadas pela faixa do dispositivo |
| `previousDefaultInputUID` | `nil` | Entrada anterior ao MicBoost assumir a padrão |
| `defaultInputManaged` | `false` | `true` enquanto a entrada padrão atual foi definida pelo MicBoost |

Esquemas desconhecidos ou corrompidos caem nos padrões, sem crash. Os campos de entrada padrão são gravados imediatamente, sem debounce, porque servem de recuperação após crash.
