# Roadmap

Status: `não iniciado` · `em andamento` · `concluído`. Uma etapa só é concluída quando as condições de conclusão foram verificadas, e os resultados medidos foram registrados em [testing.md](testing.md#resultados-registrados).

| # | Etapa | Status |
|---|---|---|
| 0 | Estrutura e diagnóstico | concluído |
| 1 | Ponte mínima | concluído |
| 2 | Ganho e proteção de pico | em andamento |
| 3 | Equalizador | concluído |
| 4 | Interface | em andamento |
| 5 | Recuperação | em andamento |
| 6 | Distribuição | em andamento |
| 7 | Entrega | não iniciado |

## 0 — Estrutura e diagnóstico

Entregas:
- `Package.swift` com todos os targets de [architecture.md](architecture.md#pacote-swift) (stubs onde for o caso);
- `scripts/build-app.sh` gerando um `.app` que abre como item de barra de menus vazio;
- camada HAL (`AudioHardware` + implementação real + `FakeAudioHardware`);
- `DeviceService`;
- `micboost-diag devices` e `capture`.

Condições de conclusão:
- `swift build` e `swift test` passam;
- `micboost-diag devices` lista corretamente os dispositivos da máquina de referência, com o BlackHole instalado;
- o UID real do BlackHole foi confirmado e [audio-engine.md](audio-engine.md#identificação-do-blackhole) atualizado;
- houve captura bruta do microfone interno e de um segundo tipo de entrada (USB/Continuity).

## 1 — Ponte mínima

Entregas: `MicBoostDSP` com passagem direta (sem efeitos, já com fade e guarda numérica), `AggregateBuilder`, `EngineController` (start/stop/estados), `micboost-diag run`, `latency` e `soak`.

Condições de conclusão:
- voz da fonte chega ao BlackHole (gravador em BlackHole);
- silêncio seguro nas falhas (desconectar a fonte durante `run`);
- latência medida com buffers de 128 e 256;
- ensaio de 20 min aprovado (sem crescimento de atraso);
- decisão confirmada: agregado (ou troca para a ponte alternativa, com a especificação reescrita);
- buffer padrão definido.


## 2 — Ganho e proteção de pico

Entregas: ganho suavizado, mute, limitador, medidores e contadores; testes DSP correspondentes. Implementação, medição com som ambiente e calibração com voz verificadas. O teto do limitador vale na saída do BlackHole: o resampler de drift fica na fonte, antes do limitador.

Condições de conclusão:
- níveis conferidos com sinal conhecido (testes) e com gravação de voz;
- faixa máxima do ganho definida e registrada em [dsp.md](dsp.md#ganho).

## 3 — Equalizador

Entregas: 3 bandas, bypass com crossfade, "Zerar EQ", suavização, limitação por taxa; persistência dos parâmetros no `SettingsStore`.

Condições de conclusão:
- testes de resposta em todas as taxas;
- sem cliques em mudanças durante o áudio;
- latência e CPU medidas com o EQ ativo.

## 4 — Interface

Entregas implementadas: item de status, painel, seção do EQ, mensagens de estado, janela de ajustes, localização pt-BR/en, política de entrada padrão integrada ao app e capturas reproduzíveis. A validação completa de teclado, VoiceOver e preferências de acessibilidade permanece pendente.

Condições de conclusão:
- abrir e fechar o painel não interrompe o áudio;
- persistência ao reabrir;
- teclado, VoiceOver, aparência clara/escura e reduzir transparência/movimento verificados;
- interface responsiva com o motor rodando.

## 5 — Recuperação

Entregas implementadas: motivos tipados de recuperação (`sourceLost`, `formatChanged`, `serviceRestarted`, `sleep`, `wakeFailed`); reconstrução por UID depois do `coreaudiod`; tentativa única 1 s após o wake; permissão reavaliada ao ativar o app; mensagens de estado por motivo; taxa de trabalho comum à fonte e ao BlackHole, com restauração no stop voluntário e na troca de fonte; `micboost-diag set-rate`; roteiro manual de recuperação em [testing.md](testing.md#recuperação-etapa-5).

Condições de conclusão: cada linha da tabela de [audio-engine.md](audio-engine.md#recuperação) verificada manualmente (desconexão, suspensão e retomada, mudança de formato, permissão negada, BlackHole ausente, mudança manual da entrada padrão, reinício do `coreaudiod`). A HAL falsa cobre a lógica e as medições com hardware cobrem a mudança de taxa; os itens que precisam de interação humana estão pendentes no roteiro manual.

## 6 — Distribuição

Entregas implementadas:
- `scripts/package-release.sh <versão>`, com build de release universal e as verificações de arquitetura, assinatura ad hoc, minos e versão descritas em [distribution.md](distribution.md#release-download-direto);
- modelo do cask em `packaging/homebrew/micboost.rb` e modelo das notas de release em `packaging/release-notes.md`;
- `.zip` + `.sha256` gerados localmente e verificados;
- `.github/workflows/ci.yml` (build, testes e lint de formatação) e `.github/workflows/release.yml` (release em rascunho a partir da tag), na imagem `xcode-27`, com `scripts/select-xcode.sh` para escolher o Xcode 27 ou posterior, que traz o SDK 27 exigido pela interface;
- evidência local de Gatekeeper: [distribution.md](distribution.md#verificação-local-por-spctl).

Pendências:
- publicação da release no GitHub (`gh release create`, com anexos `.zip` e `.sha256`);
- criação e publicação do tap `vittau/homebrew-micboost` com o cask preenchido;
- validação dos cenários de instalação e de primeira abertura em um Mac que não participou do desenvolvimento;
- variante com o instalador do BlackHole: confirmar a orientação do upstream sobre a redistribuição e validar a instalação em máquina limpa.

Condições de conclusão:
- a primeira execução da CI depois do primeiro push do mantenedor passou;
- a primeira release em rascunho, criada pelo workflow a partir de uma tag `vX.Y.Z`, foi revisada e aprovada;
- os cenários de [distribution.md](distribution.md#homebrew-tap-próprio) e da primeira abertura foram validados em um Mac que não participou do desenvolvimento;
- os resultados reais foram registrados em [distribution.md](distribution.md);
- a variante com o instalador do BlackHole está decidida (publicada ou descartada).

## 7 — Entrega

Condições de conclusão:
- README do repositório completo, conforme [distribution.md](distribution.md#readme-do-repositório), com capturas da interface final;
- medições registradas;
- artefatos publicados apenas dos canais validados.

## Decisões em aberto

| Decisão | Recomendação atual | Quando |
|---|---|---|
| Queda lenta de latência no ensaio longo | ensaio de várias horas para confirmar que se estabiliza | antes da etapa 6 |
| Homebrew 7 / macOS 27 com cask sem notarização | investigar com tap local: quarentena e "Abrir Mesmo Assim" para app ad hoc, permissão de microfone após `brew upgrade`, BlackHole já instalado, `brew uninstall` | antes da etapa 6 |
