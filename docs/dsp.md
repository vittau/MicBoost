# Processamento (MicBoostDSP)

## Cadeia

```text
canais da fonte → [mapa de canais] → low shelf → peaking → high shelf ─┐
                                                       (crossfade de bypass do EQ)
                                   ┌──────────────────────────────────┘
                                   ▼
                    ganho geral (inclui mute) → limitador (sem lookahead) → clamp ±1 → BlackHole L/R
```

- Formato interno: Float32 nos buffers; estado e coeficientes dos biquads em `double`.
- 1 canal de processamento (modos mono) ou 2 (estéreo). Estado dos filtros por canal.
- Nenhum lookahead, nenhuma fila e nenhuma latência algorítmica.
- Toda a memória é alocada em `mb_engine_create(max_frames, sample_rate)`. `mb_engine_process` não aloca.

A cadeia completa é executada no IOProc e no ponto de entrada offline, com controles atômicos e sem reiniciar o motor.

## API C (header `MicBoostDSP.h`)

As funções de controle são seguras para chamar de qualquer thread fora da de IO e escrevem apenas atômicos:

```c
mb_engine *mb_engine_create(uint32_t max_frames, double sample_rate);
void       mb_engine_destroy(mb_engine *);
int        mb_engine_configure(mb_engine *, const mb_routing *routing);   // só com o IOProc parado
void       mb_engine_set_gain_db(mb_engine *, float db);
void       mb_engine_set_muted(mb_engine *, bool);
void       mb_engine_set_eq_enabled(mb_engine *, bool);
void       mb_engine_set_band(mb_engine *, mb_band band, float freq_hz, float gain_db, float q); // q ignorado nas shelves
void       mb_engine_set_channel_mode(mb_engine *, mb_channel_mode mode, uint32_t first_channel);
void       mb_engine_begin_fade_out(mb_engine *);
void       mb_engine_read_meters(mb_engine *, mb_meters *out);            // exchange: pico desde a última leitura
void       mb_engine_read_counters(const mb_engine *, mb_counters *out);
// tempo real / offline:
void       mb_engine_process(mb_engine *, const float *const *in, float *const *out, uint32_t frames);
OSStatus   mb_ioproc(...);  // ver audio-engine.md
```

`mb_engine_process` recebe todos os canais da fonte não intercalados e aplica a seleção de canais e é o ponto de entrada dos testes offline. O IOProc extrai os canais físicos, delega o processamento e escreve os dois canais de saída. `mb_routing` comporta até 64 canais de fonte; canais C são indexados a partir de zero, enquanto settings/UI usam canais a partir de um. `mb_meters.fade_done` permite consultar a conclusão do fade sem zerar a flag.

## Equalizador

Filtros biquad do Audio EQ Cookbook (RBJ) em Transposed Direct Form II. Shelves com inclinação fixa S = 1.

| Banda | Tipo | Frequência (padrão / faixa) | Ganho | Q |
|---|---|---|---|---|
| Graves | low shelf | 70 Hz / 40–500 Hz | −6 dB / −12…+12 dB | fixo (S = 1) |
| Médios | peaking | 3.000 Hz / 200–6.000 Hz | +2 dB / −12…+12 dB | 1,0 / 0,3–4,0 ("Largura") |
| Agudos | high shelf | 8.000 Hz / 2.000–14.000 Hz | +1,5 dB / −12…+12 dB | fixo (S = 1) |

Os valores padrão formam o "padrão de voz": um realce discreto de fala para microfones em geral. O corte de −6 dB nos subgraves (≈ −3 dB em 70 Hz, ≈ −1,5 dB em 100 Hz e quase nada acima de 150 Hz) tira ronco, vibração e ruído de manuseio, que o microfone capta e a voz não precisa, e preserva o corpo da voz (fundamental e primeiros harmônicos, de 85 a 250 Hz); a presença em 3 kHz melhora a inteligibilidade; os agudos suaves acrescentam clareza. O EQ vem ligado com esse padrão.

- Estabilidade: toda frequência é limitada a `[20 Hz, 0,45 · fs]` no momento do cálculo dos coeficientes. A UI limita o slider ao máximo efetivo para a taxa atual (exemplo: Bluetooth a 16 kHz → agudos até 7.200 Hz).
- Resposta plana: com ganho 0 dB, a banda é tratada como identidade exata (coeficientes b0 = 1, demais 0), sem depender de arredondamento.
- Bypass (`eq.enabled = false`): os filtros continuam rodando, com estado aquecido, e a saída faz crossfade linear de 20 ms entre o sinal com EQ e o sem EQ.
- "Padrão de voz": volta as três bandas aos valores padrão da tabela.
- "Zerar EQ": põe o ganho das três bandas em 0 dB (resposta plana) e as frequências e o Q nos valores padrão.
- As duas ações mantêm `eq.enabled`, ganho geral, mute e fonte.
- Suavização de parâmetros: a cada bloco, os parâmetros correntes se aproximam dos alvos por um filtro de um polo com τ = 30 ms. A frequência é suavizada em escala logarítmica e o ganho em dB. Os coeficientes são recalculados por bloco somente enquanto algum parâmetro da banda está em transição (|alvo − atual| > ε). O valor é fixado no alvo quando a diferença fica abaixo de 1e−7 (log natural de Hz, dB ou Q); blocos maiores que `max_frames` são subdivididos antes dessa atualização.
- Denormais: o estado do filtro com |s| < 1e−25 é zerado ao fim de cada bloco.

## Ganho

- Faixa do controle: **−12 dB a +24 dB** (6,3% a 1.585%), passo de 0,5 dB, padrão 0 dB. O máximo de +24 dB é necessário: com um microfone USB comum na distância de uso, a voz só chega a ≈ −20 dBFS no máximo ([testing.md](testing.md#testes-manuais-com-o-mantenedor-2026-11-0304)).
- Exibição: `398% (+12,0dB)`, com percentual = 100 · 10^(dB/20) arredondado ao inteiro. 0 dB = 100%, +6,02 dB ≈ 200%.
- O percentual é de amplitude, não de volume percebido, e a proteção de pico pode reduzir o ganho efetivo.
- Aplicação: ganho linear por amostra, suavizado por filtro de um polo com τ = 20 ms rumo a `10^(dB/20)`, ou a 0 com mute.
- Mute: o alvo vai a 0 com a mesma suavização, e o medidor de saída cai. O valor de ganho é mantido.
- Fade-out (stop): o alvo vai a 0 com τ = 3 ms. Depois que o ganho fica abaixo de −90 dB, o atômico `fade_done` é sinalizado.

## Proteção de pico (limitador)

Limitador de pico sem lookahead, com ataque instantâneo:

- Teto fixo: −1,0 dBFS (0,891).
- Por amostra: `peak = max(|x_L|, |x_R|)`, `target = min(1, ceiling / peak)` (1 se peak = 0).
- Ganho do limitador `g`: se `target < g`, então `g = target` (ataque instantâneo, garante |y| ≤ teto). Caso contrário, `g` volta para 1 com liberação exponencial τ = 150 ms.
- Ligado entre canais (mesmo `g` em L e R).
- Clamp final a ±1,0 só como guarda numérica. Com o limitador correto, ele nunca deve atuar.
- Indicação: redução de ganho (GR) em dB publicada nos medidores. A UI mostra "Limitador ativo" quando o GR passa de 1 dB nos últimos 300 ms.

A distorção de transientes, consequência de não haver lookahead, é aceita na v1.

## Medidores e contadores

`mb_meters`:
- `input_peak` (linear, depois do mapa de canais e antes do EQ);
- `output_peak` (linear, depois do limitador);
- `gr_max_db` (maior redução desde a última leitura);
- `input_clipped` (houve amostra de entrada ≥ 0,999).

Todos são pico desde a última leitura.

`mb_counters` (monotônicos):
- `cycles`;
- `input_missing`;
- `nonfinite_resets`;
- `frames_over_max` (ciclos maiores que `max_frames`, processados em blocos);
- `io_delta_host` (último valor).

## Segurança numérica

Se alguma amostra de saída do bloco não for finita: zerar o estado de todos os filtros, escrever zeros no bloco inteiro e incrementar `nonfinite_resets`. As entradas não finitas são tratadas como 0 antes do processamento e incrementam `nonfinite_resets` uma vez por ciclo afetado.

## Custo esperado

Mono, 48 kHz: 3 biquads + ganho + limitador por amostra, ou seja, dezenas de MFLOPS. A carga de CPU do processo em `running` deve ficar abaixo de 2% na máquina de referência. O valor medido é registrado em [testing.md](testing.md#resultados-registrados).
