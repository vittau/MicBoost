# Produto

## Objetivo

Amplificar e equalizar o microfone escolhido pelo usuário e disponibilizar o áudio processado pelo BlackHole 2ch, com:

- interface com aparência de controle nativo do macOS (Volume/Bluetooth da Central de Controle);
- resposta imediata dos controles e latência de áudio adicional de no máximo 100 ms no uso normal (fonte → BlackHole), com arquitetura sem fila que mire < 20 ms (ver [testing.md](testing.md#medição-de-latência));
- modo monitor para ouvir a própria voz processada na saída de áudio do sistema, com latência total da fonte à saída **< 50 ms** ([audio-engine.md](audio-engine.md#modo-monitor));
- ganho acima de 200% (+6,02 dB), sem teto herdado de outra solução;
- instalação simples **sem notarização** e sem adesão paga ao Apple Developer Program.

Motivação: o VirtuMic tem interface pesada e atraso perceptível (o log dele mostra 4.410 frames de pré-preenchimento a 44,1 kHz, ou seja, 100 ms na fila). O LitLink é fechado, tem recursos pagos e, no uso avaliado, limitava o boost de microfone a 200%.

## Público e dispositivos

- Qualquer entrada compatível com Core Audio: microfone interno, USB, interfaces de áudio multicanal, Continuity (iPhone) e Bluetooth.
- Nenhum nome, modelo, UID ou formato de dispositivo específico fixado no código, exceto a identificação do BlackHole ([audio-engine.md](audio-engine.md#identificação-do-blackhole)).
- Bluetooth: suportado com limitações documentadas. O perfil de voz (HFP) usa taxa baixa (16/24 kHz), degrada a saída do próprio fone enquanto o microfone está em uso e tem latência maior.
- Continuity (iPhone): a entrada observada reporta latência de 6000 frames (125 ms a 48 kHz); o MicBoost não consegue oferecer baixa latência total com essa fonte, mesmo com pouca latência adicional ([testing.md](testing.md#resultados-registrados)).
- Sistema mínimo: macOS 14 Sonoma. Arquiteturas: arm64 e x86_64 (binário universal na release).

## Escopo da v1

1. App de barra de menus (`LSUIElement`), sem ícone no Dock, com painel compacto próprio ([ui.md](ui.md)).
2. Seletor de microfone, com captura explícita independente da entrada padrão.
3. Ganho manual em dB (com percentual equivalente), mute e proteção de pico com indicação de atuação.
4. EQ com exatamente 3 bandas (graves low shelf, médios paramétrico, agudos high shelf), chave de bypass, um padrão de voz discreto como valor inicial e as ações "Padrão de voz" e "Zerar EQ".
5. Medidores discretos de entrada e de saída.
6. Estado da conexão: fonte física, destino BlackHole e estado da entrada padrão.
7. Persistência de ganho, mute, EQ, dispositivo selecionado e seleção de canais.
8. Detecção e recuperação: BlackHole ausente, permissão de microfone negada, desconexão da fonte, suspensão/retomada, mudança de formato e mudança manual da entrada padrão.
9. Tela secundária de ajustes avançados (buffer, canais, diagnóstico).
10. Modo monitor: chave no painel que leva a voz processada também à saída padrão do sistema (fones), com latência medida < 50 ms em saídas internas, com fio e USB ([audio-engine.md](audio-engine.md#modo-monitor)).
11. Distribuição: tap Homebrew próprio com dependência do cask `blackhole-2ch` e download direto `.zip` ([distribution.md](distribution.md)).

## Fora de escopo da v1

Redução de ruído, compressor avançado, ganho automático, volume próprio do monitor, presets de EQ, gráfico de resposta, módulo da Central de Controle, Mac App Store, `homebrew/cask` oficial, notarização, iniciar no login.

Modo monitor em saídas Bluetooth: funciona, mas a latência de saída do próprio fone (tipicamente acima de 100 ms) impede a meta de 50 ms; o painel avisa quando a latência reportada passa da meta.

Limitação inerente: o ganho digital também amplifica ruído e não recupera áudio já saturado na origem. O painel indica saturação da entrada quando ela ocorre.

## Regras de roteamento (invariantes)

```text
Fonte (captura explícita) → EQ 3 bandas → ganho → proteção de pico → BlackHole 2ch → aplicativos consumidores
```

1. O MicBoost captura a fonte pelo UID, nunca pela entrada padrão.
2. Enquanto o processamento está ligado, o BlackHole deve ser a entrada padrão. O MicBoost **nunca** define o microfone físico como entrada padrão.
3. A saída padrão do sistema (fones/alto-falantes) **nunca** é alterada. A saída para o BlackHole é interna ao motor, e o modo monitor só lê qual é a saída padrão.
4. Nenhum dispositivo BlackHole pode ser fonte; ele é excluído da lista, o que impede realimentação.
5. Fechar o painel não interrompe o processamento.
6. Ao sair do app ou desligar o processamento, a entrada padrão anterior é restaurada **somente se** a entrada atual ainda for o BlackHole definido pelo MicBoost **e** o dispositivo anterior existir.
7. Se o usuário mudar a entrada padrão manualmente, o painel mostra a divergência e oferece "Usar BlackHole". O MicBoost não volta a alterar a entrada sozinho.
8. Aplicativos com seleção própria de microfone precisam estar em "BlackHole 2ch" ou em "padrão do sistema". A documentação ao usuário explica isso.

## Critérios de aceitação da v1

Áudio e roteamento:
- O BlackHole recebe a voz processada e permanece como entrada padrão durante o uso normal.
- A fonte é capturada mesmo sem ser a entrada padrão.
- Validado com o microfone interno e com pelo menos um dispositivo USB ou interface externa.
- Funciona em pelo menos um app de chamada e um gravador, tanto em "padrão do sistema" quanto com BlackHole selecionado explicitamente.

Ganho e proteção:
- O ganho aceita valores acima de +6,02 dB (200%). A indicação de pico deixa claro quando a proteção está atuando.
- Ganho, mute, EQ e bypass mudam sem reiniciar o motor e sem cliques perceptíveis.
- A proteção de pico segura boosts combinados de EQ e ganho nos extremos dos controles.

EQ:
- Exatamente low shelf, uma banda paramétrica central e high shelf.
- Resposta plana com as bandas em 0 dB. O bypass preserva o resto da cadeia.
- Resposta conferida com sinal conhecido nas taxas suportadas.
- Os parâmetros persistem; "Padrão de voz" e "Zerar EQ" não alteram os demais controles.

Estabilidade e desempenho:
- Nenhuma fila cresce indefinidamente.
- Sem cortes ou estalos no ensaio de estabilidade de 20 minutos.
- Latência, CPU, memória e condições de teste registradas em [testing.md](testing.md#resultados-registrados). Desvios da meta são documentados antes da entrega.
- A interface permanece responsiva.

Modo monitor:
- Com o monitor ligado, a voz processada (a mesma entregue ao BlackHole) sai na saída padrão do sistema, com latência medida < 50 ms (mediana) no buffer padrão em saída interna, com fio ou USB ([testing.md](testing.md#medição-de-latência-do-monitor)).
- Ligar e desligar o monitor não altera ganho, EQ, roteamento nem a entrada padrão; trocar a saída padrão com o monitor ligado leva o monitor à nova saída.
- O monitor nunca usa um BlackHole (nem um agregado que o contenha) como saída.

Recuperação:
- O áudio volta após reconectar a fonte, ou o painel explica o impedimento.

Interface:
- O painel é coerente com os controles nativos e funciona com teclado, VoiceOver, aparência clara/escura e as preferências de reduzir transparência e movimento.

Distribuição:
- Instalar via Homebrew em uma máquina sem BlackHole traz o driver no mesmo comando.
- Um BlackHole existente é reconhecido sem criar cópias.
- Atualização, falha parcial e desinstalação foram validadas; a desinstalação não remove silenciosamente o driver compartilhado.
- Cada canal anunciado funciona sem notarizar o MicBoost, inclusive em um Mac que não participou do desenvolvimento.
- Nada desativa o Gatekeeper ou o SIP, nem remove a quarentena automaticamente.
