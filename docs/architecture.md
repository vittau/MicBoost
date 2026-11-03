# Arquitetura

## Visão geral

```text
┌──────────────────────── MicBoostApp (main thread) ────────────────────────┐
│ AppKit: NSStatusItem + NSPopover  ·  SwiftUI: PanelView,     │
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

`EngineHardware` estende `AudioHardware` com criação/destruição de agregado, mapa de buffers/streams, taxa do destino, tamanho de buffer, registro/uso de IOProc e latências. A fake implementa ambas as interfaces.

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
- `SettingsStore` é um actor: o controller lê e grava com `await`, e o debounce roda como `Task` isolada nele. `DefaultInputManager` não é `Sendable` e seus métodos assíncronos são `nonisolated(nonsending)`: herdam o executor de quem chama, então rodam e retomam na fila `engine` mesmo depois de cada `await` ao `SettingsStore`; um método `nonisolated async` comum rodaria no pool cooperativo e tocaria a HAL fora da fila. O controller serializa as chamadas.
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
- `stop` faz uma rampa de saída para zero (τ = 3 ms, atingindo −90 dB em aproximadamente 31 ms; espera de 40 ms com limite de 50 ms), `AudioDeviceStop`, destrói o IOProc, destrói o agregado e restaura a entrada padrão conforme a política.
- Ganho, mute, EQ, bypass e modo de canais **nunca** reiniciam o motor. Mudar a fonte ou o tamanho de buffer reconstrói o motor (stop → start), com rampa.

## Modelo de domínio (MicBoostCore)

- `AudioDevice`: `id: AudioObjectID`, `uid: String`, `name: String`, `manufacturer`, `transport` (builtIn, usb, bluetooth, bluetoothLE, aggregate, virtual, continuity/unknown…), `inputChannels`, `outputChannels`, `nominalSampleRate`, `availableSampleRates`, `bufferFrameSizeRange`, `isAlive`.
- `DeviceService` publica `[AudioDevice]` de entrada elegíveis (ver exclusões em [audio-engine.md](audio-engine.md#enumeração-e-elegibilidade)), o BlackHole detectado (se houver) e o UID da entrada padrão atual.
- `Settings`: preferências persistidas, com `EQSettings` (`low`, `mid`, `high`) e `ChannelSelection` (`auto`, `mono(canal)`, `monoMix`, `stereo(primeiroCanal)`, canais baseados em 1). `SettingsStore` é o actor que as lê e grava ([Persistência](#persistência)).
- `DefaultInputManager`: aplica a [política de entrada padrão](audio-engine.md#política-de-entrada-padrão-defaultinputmanager) sobre `AudioHardware` e `SettingsStore`, e publica `DefaultInputStatus`.
- `EngineStatus` (snapshot enviado à UI): `state`, `source: AudioDevice?`, `blackHole: AudioDevice?`, `defaultInput: DefaultInputStatus` (`isBlackHole`, `divergedByUser`, `unknown`), `sampleRate`, `bufferFrames`, `reportedLatencyMs`, contadores (overloads, eventos NaN).

## Persistência

`SettingsStore` é um actor que mantém `Settings: Codable, Sendable, Equatable` versionado por `schemaVersion` (atual: 1) e o grava como JSON na chave `io.github.vittau.MicBoost.settings`. O armazenamento fica atrás do protocolo `SettingsStorage` (`data(forKey:)` / `setData(_:forKey:)`): `UserDefaultsStorage` na suíte padrão do bundle e um armazenamento em memória nos testes. `update` cobre os campos comuns e grava com debounce de 300 ms; `updateDefaultInput` cobre os campos de entrada padrão e grava imediatamente; `flush` antecipa uma gravação pendente. Atualizações que não mudam nada não gravam.

| Campo | Padrão | Notas |
|---|---|---|
| `schemaVersion` | `1` | Versão diferente da atual → padrões |
| `processingEnabled` | `true` | Liga/desliga o motor ao abrir o app |
| `manageDefaultInput` | `true` | Com `false`, o MicBoost nunca altera a entrada padrão do sistema ([política](audio-engine.md#política-de-entrada-padrão-defaultinputmanager)) |
| `selectedInputUID` | `nil` | Primeira execução: entrada padrão atual, se elegível; senão, a primeira elegível |
| `gainDB` | `0` | Faixa em [dsp.md](dsp.md#ganho) |
| `muted` | `false` | |
| `eq` | ver [dsp.md](dsp.md#equalizador) | `enabled` (padrão `true`), `low{frequency, gainDB}`, `mid{frequency, gainDB, q}`, `high{frequency, gainDB}` |
| `channelSelectionByUID` | `[:]` | Modo de canais por dispositivo ([audio-engine.md](audio-engine.md#canais)), codificado como `{mode, channel}` com canal baseado em 1 |
| `bufferFrames` | `256` | Opções 64/128/256/512/1024, limitadas pela faixa do dispositivo |
| `previousDefaultInputUID` | `nil` | Entrada anterior ao MicBoost assumir a padrão |
| `defaultInputManaged` | `false` | `true` enquanto a entrada padrão atual foi definida pelo MicBoost |

Cada campo é decodificado isoladamente (`decodeIfPresent`), então um campo ausente mantém o padrão. Esquemas desconhecidos ou dados corrompidos caem nos padrões, sem crash. Valores fora das faixas documentadas (ganho, buffer, frequência/ganho/Q do EQ) são limitados, e seleções de canal inválidas são descartadas na leitura. Os campos de entrada padrão são gravados imediatamente, sem debounce, porque servem de recuperação após crash.

## Interface do app

`MicBoostUI` é uma biblioteca interna com `AppModel`, `PanelView` e `SettingsView`,
localizações `.strings` e dependência apenas de MicBoostCore e frameworks do sistema.
O executável auxiliar `render-screenshots` reutiliza as views sem iniciar captura.
`AppDelegate` mantém o item, popover nativo, janela de ajustes e notificações de suspensão; o encerramento
assíncrono aguarda `AppModel.shutdown`, stop com fade, restauração e flush dos ajustes.
O controller mantém `DefaultInputManager` e seu listener de entrada padrão na fila engine.
Comandos de processamento são serializados pelo modelo para preservar a ordem dos cliques.

O painel usa `NSPopover` `.transient` e `NSHostingController` com
`sizingOptions = .preferredContentSize`. O AppKit controla a apresentação, moldura
e fechamento externo. O delegate acompanha a visibilidade para ligar/desligar os
medidores; o conteúdo trata Escape com `onExitCommand`. Não há janela, material
ou monitores globais de clique implementados pelo app para esse painel.
