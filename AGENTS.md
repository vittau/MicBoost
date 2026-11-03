# AGENTS.md — MicBoost

MicBoost é um app nativo de barra de menus para macOS: captura o microfone escolhido, aplica EQ de 3 bandas, ganho e proteção de pico, e entrega o áudio ao BlackHole 2ch, que fica como entrada padrão do sistema.

## Especificação primeiro

- `docs/` é a fonte da verdade. Comece por `docs/README.md`. Antes de mexer em uma área, leia o documento dela (motor → `docs/audio-engine.md`, DSP → `docs/dsp.md`, UI → `docs/ui.md`…).
- O código implementa a especificação. Se for preciso divergir (a API não existe, a medição reprova a decisão), atualize o documento **na mesma mudança**. Nunca deixe código e documentação discordarem.
- Os documentos descrevem apenas o estado atual: sem histórico, sem "antes era X" e sem diário de decisões. Os documentos são enxutos e completos; o detalhe técnico necessário para continuar o trabalho fica neles, não em comentários soltos nem em mensagens de commit.
- Medições vão para `docs/testing.md#resultados-registrados`. O status das etapas fica em `docs/roadmap.md`.
- Documentação em pt-BR. Código, identificadores, comentários e mensagens de commit em inglês.

## Comandos

```sh
swift build                           # compila todos os targets
swift test                            # testes (sem hardware de áudio)
scripts/build-app.sh debug            # monta e assina ad hoc build/MicBoost.app
open build/MicBoost.app               # roda o app
swift run micboost-diag devices       # lista dispositivos de áudio (requer hardware)
swift run micboost-diag run --input <uid> --seconds 30
scripts/package-release.sh <versão>   # zip + sha256 de release
```

Toolchain: Xcode 27.2 / Swift 6.4. Alvo mínimo: macOS 14. Não há `.xcodeproj`; não crie um.

## Layout

- `Sources/MicBoostDSP/`: C17, tudo que roda na thread de áudio (IOProc, EQ, ganho, limitador, medidores).
- `Sources/MicBoostCore/`: Swift. HAL, dispositivos, agregado, `EngineController`, política de entrada padrão e settings. Sem AppKit/SwiftUI.
- `Sources/MicBoostApp/`: Swift. App, item de status, painel e ajustes (AppKit + SwiftUI).
- `Sources/micboost-diag/`: CLI de diagnóstico e medição.
- `Tests/`: Swift Testing. `MicBoostDSPTests` (offline) e `MicBoostCoreTests` (HAL falsa).
- `Resources/`, `scripts/`, `packaging/homebrew/`, `docs/`.

## Regras invioláveis

Tempo real (thread de IO / `mb_ioproc` / `mb_engine_process`):
- Só C. Nada de Swift ou Objective-C, alocação/liberação, locks, I/O, logs, `printf` ou chamadas à HAL.
- Toda a memória é pré-alocada em `mb_engine_create`. Parâmetros chegam por atômicos; medidores saem por atômicos.

Roteamento:
- Nunca definir um microfone físico como entrada padrão.
- Nunca alterar a saída padrão do sistema.
- Nunca aceitar um BlackHole como fonte.
- Restaurar a entrada anterior só nas condições de `docs/audio-engine.md`.
- Nunca disputar a entrada padrão com o usuário.

Dispositivos:
- Nada de nomes, UIDs ou formatos de modelos específicos no código, exceto a identificação do BlackHole.

Distribuição:
- Sem notarização, sem Developer ID e sem credenciais pagas.
- Nada que desative o Gatekeeper ou o SIP, nem remova a quarentena (`xattr -d`, `--no-quarantine` etc.).

Controles:
- Ganho, mute, EQ, bypass e modo de canais não reiniciam o motor.

## Convenções de código

- Swift formatado com `swift format`, usando `.swift-format` na raiz; executar antes de commitar.
- C: indentação de 4 espaços, uma instrução por linha, chaves em todos os corpos de `if`/`for` e linhas de até 100 colunas.

- Swift 6 com concorrência estrita e sem `@unchecked Sendable` sem justificativa em comentário.
  - UI em `@MainActor` com `@Observable`.
  - `EngineController` é um actor sobre uma `DispatchSerialQueue` própria. Listeners HAL vão para essa fila.
- Todo `OSStatus` da HAL é verificado e convertido em erro tipado (`EngineError.halFailure(status, operation)`). Nada de `try!` nem de force unwrap em caminhos de dispositivo.
- Código que toca a HAL passa pelo protocolo `AudioHardware`, para ser testável com `FakeAudioHardware`.
- Strings de UI localizadas (`String(localized:)`, String Catalog) em en e pt-BR.
- Logs com `os.Logger(subsystem: "io.github.vittau.MicBoost", category: …)`, nunca na thread de IO.
- Prefira APIs do sistema a dependências externas. Adicionar um pacote exige justificativa e atualização de `docs/architecture.md`.

## Verificação

- Toda mudança deve terminar com `swift build` e `swift test` verdes. Mudanças de DSP exigem testes em `MicBoostDSPTests` (resposta, ausência de cliques e limites, conforme `docs/testing.md`).
- Comportamento com hardware real (latência, estabilidade, recuperação) é verificado com `micboost-diag`. Agentes não conseguem ouvir áudio: relate números medidos, não impressões.
- A permissão de microfone pertence ao app de terminal que executa o `micboost-diag`. Se a captura vier zerada, verifique a permissão antes de depurar.
- Não declare uma etapa concluída sem cumprir as condições de `docs/roadmap.md`. Diga explicitamente o que não foi possível verificar (por exemplo, "requer teste manual com USB").
- Encerre todo processo que você iniciou (`MicBoost.app`, `micboost-diag run`/`soak`) antes de terminar a tarefa. Um app esquecido continua na barra de menus do mantenedor e pode alterar a entrada padrão.

## Git

- Branch principal `main`. Trabalhe em branch ou worktree próprios (`feat/…`, `fix/…`, `docs/…`).
- Commits pequenos, mensagem em inglês no imperativo (`Add aggregate device builder`).
- Não faça push, release nem publicação no tap sem pedido explícito do mantenedor.
- Não commite `build/`, `dist/`, `.build/` nem `.scratch/`.
