# Build e distribuição

## Restrição

O MicBoost **não** é notarizado nem usa credenciais pagas do Apple Developer Program. A assinatura é ad hoc (`codesign --sign -`), apresentada como tal e nunca como Developer ID. O app não desativa o Gatekeeper nem o SIP e não remove a quarentena automaticamente. A assinatura e a notarização do pacote upstream do BlackHole são preservadas.

Canais excluídos: Mac App Store, `homebrew/cask` oficial (as regras exigem passar no Gatekeeper na configuração padrão) e qualquer fluxo que dependa de notarização do MicBoost.

## Identidade

- Nome do app: `MicBoost.app`. Bundle ID: `io.github.vittau.MicBoost`.
- Repositório: `github.com/vittau/MicBoost`. Tap: `github.com/vittau/homebrew-micboost` (`brew tap vittau/micboost`).
- Versão: SemVer em `CFBundleShortVersionString` e contador de build em `CFBundleVersion`. A fonte da verdade é a tag git `vX.Y.Z`.
- Doações: `.github/FUNDING.yml` (`github: vittau`, `buy_me_a_coffee: vittau`) ativa o botão Sponsor do repositório, junto com a opção Settings → General → Features → Sponsorships, que é ligada manualmente no GitHub.

## Build

`scripts/build-app.sh [debug|release]`:
1. `swift build -c <config> --product MicBoost`. Na release: `--arch arm64 --arch x86_64` (universal).
2. Monta `build/MicBoost.app/Contents/{MacOS/MicBoost, Info.plist, Resources/…}` (recursos do bundle SwiftPM + `AppIcon.icns`).
3. `Info.plist` (`Resources/Info.plist`), com a versão substituída pelo script:
   - `LSUIElement = YES`;
   - `LSMinimumSystemVersion = 14.0`;
   - `NSMicrophoneUsageDescription`;
   - `CFBundleIdentifier`;
   - `CFBundleDevelopmentRegion = en`;
   - `CFBundleLocalizations = [en, pt-BR]`.
4. Registra no `LC_BUILD_VERSION` do executável o SDK real do Xcode selecionado (`xcrun --sdk macosx --show-sdk-version`), com `scripts/record-build-sdk.sh`/`vtool`, preservando macOS 14 como mínimo e verificando os dois valores. Isso permite ao AppKit escolher a aparência correspondente ao SDK de compilação, em vez de confundir SDK com deployment target.
5. Assina com `codesign --force --deep --sign - build/MicBoost.app`, sem hardened runtime e sem entitlements: não há sandbox e o runtime não é exigido sem notarização.
6. Confere com `codesign --verify --strict build/MicBoost.app`.

O script chama `scripts/compile-icon.sh <App>/Contents/Resources` quando o arquivo existe e é executável. Esse helper fornece `AppIcon.icns` e, opcionalmente, `Assets.car`. O plist define `CFBundleIconFile` e `CFBundleIconName` como `AppIcon`. Sem o helper, o bundle de desenvolvimento continua compilável, sem ícone personalizado. Os bundles de localização SwiftPM são copiados para `Contents/Resources`. A versão vem da última tag `v*` (fallback de desenvolvimento `0.0.0`) e o contador é `git rev-list --count HEAD`. Release sempre usa assinatura ad hoc.

No Apple Silicon, todo binário precisa de assinatura válida para executar; a ad hoc basta.

Desenvolvimento: a assinatura ad hoc muda o cdhash a cada build, e o macOS pode pedir de novo a permissão de microfone. Opcionalmente, crie no Acesso às Chaves um certificado autoassinado local de assinatura de código ("MicBoost Dev", gratuito) e exporte `MICBOOST_SIGN_IDENTITY="MicBoost Dev"`, que o script usa no lugar de `-`. Nunca usar esse certificado nos artefatos de release.

### Ícone do app

A fonte em camadas está em `Resources/AppIcon.icon`, com SVGs e variantes clara, escura e tonalizada do material Liquid Glass do Icon Composer. `scripts/compile-icon.sh <diretório>` usa o `actool` do Xcode selecionado, com destino mínimo macOS 14.0, e completa o ícone legado com `ictool` e `iconutil`: grava `AppIcon.icns` (16 a 1024 px, compatível com macOS 14 e posteriores) e `Assets.car`, quando produzido pela ferramenta, no diretório informado. As prévias PNG, incluindo as aparências transparentes geradas pelo Icon Composer, ficam em `design/icon/previews/`; `design/icon/render-previews.sh` as regenera.

## Release (download direto)

`scripts/package-release.sh <versão>`:
1. Build de release universal.
2. `ditto -c -k --keepParent build/MicBoost.app dist/MicBoost-<versão>.zip`.
3. `shasum -a 256` → `dist/MicBoost-<versão>.zip.sha256`.
4. Imprime o trecho do cask com `version` e `sha256` atualizados.

Publicação (com `gh release create`, mediante confirmação do mantenedor): anexar `.zip` + `.sha256`. As notas devem trazer as instruções de instalação, o aviso **"não notarizado"** e a instalação do BlackHole.

## Homebrew (tap próprio)

`packaging/homebrew/micboost.rb` é o modelo publicado em `Casks/micboost.rb` do tap:

```ruby
cask "micboost" do
  version "X.Y.Z"
  sha256 "…"

  url "https://github.com/vittau/MicBoost/releases/download/v#{version}/MicBoost-#{version}.zip"
  name "MicBoost"
  desc "Menu bar microphone booster and EQ that routes to BlackHole"
  homepage "https://github.com/vittau/MicBoost"

  depends_on macos: ">= :sonoma"
  depends_on cask: "blackhole-2ch"

  app "MicBoost.app"

  uninstall quit: "io.github.vittau.MicBoost"

  zap trash: [
    "~/Library/Preferences/io.github.vittau.MicBoost.plist",
  ]

  caveats <<~EOS
    MicBoost is not notarized. On first launch macOS will block it:
    open System Settings › Privacy & Security and click "Open Anyway".
    BlackHole 2ch is installed as a dependency and is NOT removed when
    MicBoost is uninstalled (other apps may use it).
  EOS
end
```

Comportamento a validar (etapa 7):
- `brew install --cask vittau/micboost/micboost` em uma máquina sem BlackHole instala o `blackhole-2ch`, que pede a senha de administrador (pkg) e pode exigir reiniciar o `coreaudiod`, e depois o MicBoost, num único comando.
- Com o BlackHole já instalado pelo Homebrew, nada é duplicado. Com o BlackHole instalado manualmente (pkg), o Homebrew tenta instalar o cask; validar se o pkg reinstala sobre o existente sem conflito e documentar o resultado aqui.
- `brew upgrade` substitui o app. As configurações (UserDefaults) permanecem.
- `brew uninstall micboost` remove só o app; o BlackHole permanece.
- O Homebrew aplica quarentena ao app baixado, e o fluxo de primeira abertura é o mesmo do download direto. Não usar nem recomendar opções que removam a quarentena.

## Primeira abertura (sem notarização)

1. Abrir o MicBoost. O macOS bloqueia ("não foi possível verificar…").
2. Ajustes do Sistema → Privacidade e Segurança → "Abrir Mesmo Assim" → confirmar com senha ou Touch ID.
3. Nas aberturas seguintes, não há aviso. Uma atualização para um novo binário pode repetir o fluxo; validar e documentar.

No macOS 15 ou posterior, o atalho de Control-clique → Abrir não contorna mais o bloqueio; o caminho é o item 2. As instruções ao usuário ficam no README do repositório e nas notas de release.

## BlackHole no download direto

- O `.zip` contém só o app. A instalação do BlackHole é instruída à parte: `brew install --cask blackhole-2ch` ou o instalador oficial do upstream.
- Uma variante com o app + o `.pkg` upstream intacto do BlackHole 2ch (duas ações de instalação) **só** é publicada depois de:
  - definir a licença do MicBoost;
  - confirmar que a redistribuição atende à orientação do upstream (GPL-3.0; o upstream pede contato para outros arranjos);
  - validar a instalação em máquina limpa.
- Um `.pkg` conjunto não é requisito; seria descartado se exigisse notarização.
- O app detecta o BlackHole em execução ([audio-engine.md](audio-engine.md#identificação-do-blackhole)), sem verificar instalador ou versão.

## Desinstalação

- Homebrew: `brew uninstall --cask micboost` (`--zap` remove também as preferências).
- Manual: sair do app, apagar `/Applications/MicBoost.app` e, se quiser, `defaults delete io.github.vittau.MicBoost`.
- O BlackHole nunca é removido pelo MicBoost. Para removê-lo: `brew uninstall --cask blackhole-2ch` ou as instruções do upstream.
- Antes de desinstalar, sair do app, para que a entrada padrão seja restaurada.

## README do repositório

`README.md` na raiz, em inglês, é a página pública do projeto. Ele combina a clareza de seções do [README do VirtuMic](https://github.com/ShotgunZZ/VirtuMic) com a riqueza visual do [README do Doom-Deck-Launcher](https://github.com/vittau/Doom-Deck-Launcher), sem copiar texto de nenhum dos dois.

Estrutura, nesta ordem:
1. **Cabeçalho:** imagem centralizada com o ícone e o nome "MicBoost", nas variantes clara e escura (`<picture>` com `prefers-color-scheme`), em `docs/design/readme/header-{light,dark}.png`. As imagens são geradas por script a partir de `Resources/AppIcon.icon` (ou das prévias em `design/icon/previews/`), não desenhadas à mão.
2. Título, badges (macOS 14+, Apple Silicon + Intel, Swift 6, licença quando definida, "not notarized") e uma frase do que o app faz.
3. Callout `> [!NOTE]`: o projeto é desenvolvido e mantido com ajuda de agentes de IA, sob direção e revisão do mantenedor.
4. Callout de status (`> [!WARNING]`) enquanto não houver release: o que já funciona e o que falta, coerente com [roadmap.md](roadmap.md).
5. **Capturas:** grade em tabela com o painel (clara/escura), o EQ expandido, a janela de ajustes e um estado de erro, mais uma legenda dizendo como as imagens foram geradas. As capturas são renderizações das views SwiftUI reais com estado de exemplo, geradas por `scripts/render-screenshots.sh` em `docs/screenshots/`. A seção só existe depois que a interface existir (etapa 4). O README é para usuários e não descreve detalhes de implementação ou de design, como o ícone.
6. **How it works:** diagrama da cadeia (fonte → EQ → ganho → proteção de pico → BlackHole → apps) e um parágrafo sobre o dispositivo agregado sem fila e o porquê da baixa latência.
7. **Features**, **Requirements**, **Install** (só os canais validados; antes disso, só "Build from source"), **First launch** (fluxo "Abrir Mesmo Assim" de [Primeira abertura](#primeira-abertura-sem-notarização), sem `xattr` nem remoção de quarentena), **Usage** (passos numerados, incluindo selecionar "BlackHole 2ch" ou "padrão do sistema" no app de chamada), **Latency** (números medidos de [testing.md](testing.md#resultados-registrados) e o método), **Known limitations** (Bluetooth, Continuity, microfone interno com a tampa fechada, ganho digital), **Troubleshooting**, **Uninstall**, **Building from source**, **Support** (GitHub Sponsors e Buy Me a Coffee, com botões/badges para `github.com/sponsors/vittau` e `buymeacoffee.com/vittau`), **License**, **Credits** (BlackHole e as referências de inspiração, deixando claro que é uma implementação independente).

Manutenção: toda mudança visível ao usuário (recurso, instalação, limitação, medição) atualiza o README na mesma mudança. As capturas são regeneradas quando a UI muda. O cabeçalho é regenerado por `scripts/render-readme-header.sh`, que executa `design/readme/RenderHeader.swift` sobre as prévias do ícone e regrava `docs/design/readme/header-{light,dark}.png`.

## Licenciamento

A licença do MicBoost ainda não foi definida (ver [roadmap.md](roadmap.md#decisões-em-aberto)). O MicBoost não incorpora código do BlackHole; ele o usa como dispositivo Core Audio. A redistribuição do instalador do BlackHole está sujeita às regras acima.
