# MicBoost — especificação

MicBoost é um aplicativo nativo de barra de menus para macOS. Ele captura explicitamente o microfone escolhido pelo usuário, aplica EQ de 3 bandas, ganho (inclusive acima de +6 dB / 200%) e proteção de pico, e entrega o resultado ao dispositivo virtual **BlackHole 2ch**. O BlackHole fica como entrada padrão do macOS, e os aplicativos consumidores (chamadas, gravadores) recebem a voz processada.

Esta pasta é a fonte da verdade do projeto (desenvolvimento orientado a especificação). O código segue os documentos; quando uma decisão muda, o documento correspondente é atualizado na mesma mudança. Os documentos descrevem apenas o estado atual, sem histórico.

## Índice

| Documento | Conteúdo |
|---|---|
| [product.md](product.md) | Objetivo, escopo da v1, fora de escopo, regras de roteamento e critérios de aceitação |
| [architecture.md](architecture.md) | Pacote, módulos, threads, fluxo de dados, ciclo de vida e persistência |
| [audio-engine.md](audio-engine.md) | Core Audio: dispositivos, dispositivo agregado, IOProc, formatos, canais, entrada padrão e recuperação |
| [dsp.md](dsp.md) | Cadeia de processamento: EQ, ganho, limitador, medidores, suavização e segurança numérica |
| [ui.md](ui.md) | Painel da barra de menus, tela de ajustes, mensagens de estado e acessibilidade |
| [testing.md](testing.md) | Testes automatizados, ferramenta de diagnóstico, medição de latência, ensaio de estabilidade e roteiro manual |
| [distribution.md](distribution.md) | Build, assinatura ad hoc, release `.zip`, tap Homebrew, primeira abertura, desinstalação e licenciamento |
| [roadmap.md](roadmap.md) | Etapas, condições de conclusão, status atual e decisões em aberto |

## Glossário

- **Fonte:** microfone físico (ou interface) escolhido pelo usuário, identificado pelo UID do Core Audio.
- **Destino:** BlackHole 2ch, saída interna do MicBoost.
- **Entrada padrão:** `kAudioHardwarePropertyDefaultInputDevice` do sistema. Durante o uso, deve ser o BlackHole.
- **Motor:** dispositivo agregado privado + IOProc + processador DSP que levam a fonte ao destino.
- **Processador:** código C de tempo real que executa a cadeia DSP dentro do IOProc.
- **Latência adicional:** atraso entre o sinal da fonte capturado diretamente e o mesmo sinal lido do BlackHole (método em [testing.md](testing.md#medição-de-latência)).
- **Proteção de pico / limitador:** estágio final que reduz o ganho efetivo para impedir clipping.

## Referências externas

- [BlackHole](https://github.com/ExistentialAudio/BlackHole): driver, instalação e orientação de licenciamento.
- [VirtuMic](https://github.com/ShotgunZZ/virtumic): referência funcional de integração com BlackHole e do EQ de 3 bandas. Não copiar a arquitetura.
- [Apple TN2091](https://developer.apple.com/library/archive/technotes/tn2091/): referência conceitual arquivada sobre captura com AUHAL. Conferir as APIs no SDK atual.
- [Audio EQ Cookbook (RBJ)](https://www.w3.org/TR/audio-eq-cookbook/): fórmulas dos filtros.
- Homebrew: [tap próprio](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap), [`depends_on`](https://docs.brew.sh/Cask-Cookbook#stanza-depends_on), [regras do repositório oficial](https://docs.brew.sh/Acceptable-Casks).
- [Apple — abrir apps de desenvolvedores não identificados](https://support.apple.com/en-us/102445).
