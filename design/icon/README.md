# Ícone do MicBoost

O microfone prateado identifica a captura de voz; três barras ascendentes em verde-água indicam amplificação. A silhueta simples, o fundo azul discreto e a ausência de detalhes de grade preservam a leitura em tamanhos pequenos.

A fonte editável é `Resources/AppIcon.icon`: três SVGs de 1024 × 1024 pontos, agrupados em microfone e amplificação. O Icon Composer aplica material de vidro às camadas, com iluminação, realces especulares, refração, translucidez e sombras configurados no documento; os efeitos não estão gravados nos SVGs.

A variante escura usa fundo azul profundo e mantém o contraste do símbolo. A especialização tonalizada usa luminâncias neutras para receber a cor do sistema; as variantes transparentes (`ClearLight` e `ClearDark`) são renderizadas pelo Icon Composer a partir das mesmas camadas de vidro.

`design/icon/render-previews.sh` regenera os PNGs com o `ictool` do Xcode selecionado, em macOS, nas seis aparências e nos tamanhos 1024, 128, 32 e 16 px. Os arquivos ficam em `design/icon/previews/<aparência>-<tamanho>.png`, com aparências `light`, `dark`, `tinted-light`, `tinted-dark`, `clear-light` e `clear-dark`.

`scripts/compile-icon.sh <diretório>` compila o documento com `actool` e destino mínimo macOS 14.0. O script usa também `ictool` e `iconutil` para completar o `.icns` com tamanhos de 16 a 1024 px, incluindo representações Retina, compatíveis com sistemas anteriores ao Liquid Glass; `Assets.car` leva as representações modernas ao bundle. O build requer o Xcode com Icon Composer; não requer `uv` nem dependências Python.
