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
4. Registra no `LC_BUILD_VERSION` do executável o SDK real do Xcode selecionado (`xcrun --sdk macosx --show-sdk-version`), com `scripts/record-build-sdk.sh`/`vtool`, preservando macOS 14 como mínimo e verificando os dois valores nos dois slices do binário universal. Isso permite ao AppKit escolher a aparência correspondente ao SDK de compilação, em vez de confundir SDK com deployment target.
5. Assina com `codesign --force --deep --sign - build/MicBoost.app`, sem hardened runtime e sem entitlements: não há sandbox e o runtime não é exigido sem notarização.
6. Confere com `codesign --verify --strict build/MicBoost.app`.

O Xcode precisa ser 27 ou posterior: a interface usa `NSMenuItem.preferredImageVisibility`, que só existe no SDK 27, e é esse SDK que o passo 4 registra no binário.

O script chama `scripts/compile-icon.sh <App>/Contents/Resources` quando o arquivo existe e é executável. Esse helper fornece `AppIcon.icns` e, opcionalmente, `Assets.car`. O plist define `CFBundleIconFile` e `CFBundleIconName` como `AppIcon`. Sem o helper, o bundle de desenvolvimento continua compilável, sem ícone personalizado. Os bundles de localização SwiftPM são copiados para `Contents/Resources`. A versão vem de `MICBOOST_VERSION` quando a variável está definida e, sem ela, da última tag `v*` (fallback de desenvolvimento `0.0.0`); o contador é `git rev-list --count HEAD`. Release sempre usa assinatura ad hoc.

No Apple Silicon, todo binário precisa de assinatura válida para executar; a ad hoc basta.

Desenvolvimento: a assinatura ad hoc muda o cdhash a cada build, e o macOS pode pedir de novo a permissão de microfone. Opcionalmente, crie no Acesso às Chaves um certificado autoassinado local de assinatura de código ("MicBoost Dev", gratuito) e exporte `MICBOOST_SIGN_IDENTITY="MicBoost Dev"`, que o script usa no lugar de `-`. Nunca usar esse certificado nos artefatos de release.

### Ícone do app

A fonte em camadas está em `Resources/AppIcon.icon`, com SVGs e variantes clara, escura e tonalizada do material Liquid Glass do Icon Composer. `scripts/compile-icon.sh <diretório>` usa o `actool` do Xcode selecionado, com destino mínimo macOS 14.0, e completa o ícone legado com `ictool` e `iconutil`: grava `AppIcon.icns` (16 a 1024 px, compatível com macOS 14 e posteriores) e `Assets.car`, quando produzido pela ferramenta, no diretório informado. As prévias PNG, incluindo as aparências transparentes geradas pelo Icon Composer, ficam em `design/icon/previews/`; `design/icon/render-previews.sh` as regenera.

## Release (download direto)

`scripts/package-release.sh <versão>`:
1. Aceita apenas SemVer `X.Y.Z`, sem `v`. Qualquer outro argumento sai com código 2 e a mensagem de uso. Falha também quando `HEAD` tem uma tag `vX.Y.Z` diferente da versão pedida, para o `.zip` nunca divergir da tag publicada.
2. Build de release universal com `scripts/build-app.sh release`, entregando a versão pela variável `MICBOOST_VERSION`; é ela que sobrepõe a última tag `v*` no `Info.plist`.
3. `ditto -c -k --keepParent build/MicBoost.app dist/MicBoost-<versão>.zip`.
4. `shasum -a 256` → `dist/MicBoost-<versão>.zip.sha256`, no formato do `shasum -c` (hash e nome do arquivo).
5. Verifica, e falha se não passar: `lipo -archs` do executável com `arm64` e `x86_64`; `codesign --verify --strict --deep`; assinatura ad hoc (`Signature=adhoc` em `codesign -dv`); `LC_BUILD_VERSION` com minos igual a `LSMinimumSystemVersion` (14.0) nos dois slices; `CFBundleShortVersionString` igual à versão pedida.
6. Imprime o tamanho do `.zip`, o checksum e o cask preenchido por `scripts/print-cask.sh`, lido de `packaging/homebrew/micboost.rb`.

Publicação (com `gh release create`, mediante confirmação do mantenedor): anexar `.zip` + `.sha256`. As notas de release seguem o modelo de `packaging/release-notes.md`, renderizado por `scripts/render-release-notes.sh <versão>`, que troca `X.Y.Z` e o marcador do checksum: instruções de instalação, aviso **"não notarizado"**, instalação do BlackHole, primeira abertura, licença GPL-3.0 com link para `LICENSE` e o checksum da versão. O `.zip` contém só o app; a licença fica no repositório. A seção de instalação pelo Homebrew só entra no modelo depois que o tap existir e for validado.

## Integração contínua e release automática

`.github/workflows/ci.yml` roda em push para `main` e em pull request: seleciona o Xcode, `swift build`, `swift test` e `swift format lint --strict` em `Sources`, `Tests` e `Package.swift`. O `concurrency` cancela execuções antigas do mesmo ref, e o job tem `timeout-minutes`.

`.github/workflows/release.yml` roda quando o mantenedor empurra uma tag `v*.*.*`:
1. checkout com `fetch-depth: 0`, porque o build lê as tags e `git rev-list --count`;
2. `swift test`;
3. `scripts/package-release.sh "${GITHUB_REF_NAME#v}"`;
4. falha, com mensagem clara, se já existir release para a tag: nunca sobrescreve;
5. renderiza as notas com `scripts/render-release-notes.sh`;
6. `gh release create "$GITHUB_REF_NAME" --draft --verify-tag --notes-file <notas>`, anexando o `.zip` e o `.sha256`;
7. escreve o cask preenchido, por `scripts/print-cask.sh`, no resumo do job.

A release sai sempre como rascunho: o mantenedor revisa, completa o marcador de mudanças das notas e publica. O tap não é tocado pelo workflow; `Casks/micboost.rb` é atualizado à mão com o trecho do resumo.

Os dois workflows usam `runs-on: xcode-27` (GitHub-hosted, arm64, imagem em preview) e `scripts/select-xcode.sh`, que escolhe o `Xcode_*.app` mais recente em `/Applications` com versão 27 ou posterior e falha com mensagem clara quando não encontra nenhum. A exigência vem do SDK, não do Swift: a interface usa `NSMenuItem.preferredImageVisibility`, que só existe no SDK 27, e a release precisa ser compilada contra ele porque `scripts/record-build-sdk.sh` grava o SDK real no `LC_BUILD_VERSION` e é dele que o AppKit tira a geração de controles. A imagem `xcode-27` é a única do GitHub Actions com Xcode 27 — macOS 27 com Xcode 27.2, 27.1 (padrão) e 27.0 —, enquanto `macos-26` para no Xcode 26.6, cujo SDK 26 não compila esse código e faria a release registrar SDK 26. O Xcode escolhido, o `swift --version` e a versão do SDK aparecem no log, e o passo falha com `::error::` quando o SDK selecionado é anterior ao 27. A imagem é arm64; a release universal compila o slice x86_64 na mesma máquina pelos `--arch` do `swift build` em `scripts/build-app.sh`. Nenhum segredo é configurado: o token do próprio GitHub (`github.token`) cobre a criação do rascunho.

O `.github/actionlint.yaml` declara o rótulo `xcode-27`: o actionlint 1.7.12 é anterior a essa imagem e conhece apenas os rótulos por versão de macOS, então sem essa declaração o lint acusa `runner-label`.

## Homebrew (tap próprio)

`packaging/homebrew/micboost.rb` é o modelo do cask, publicado como `Casks/micboost.rb` no tap. `version` e `sha256` ficam como marcadores (`X.Y.Z` e `SHA256`); `scripts/package-release.sh` imprime o arquivo com os dois valores da release, e esse é o texto a copiar para o tap:

```ruby
cask "micboost" do
  version "X.Y.Z"
  sha256 "SHA256"

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

## Verificação local por `spctl`

Avaliação de um `.app` extraído do `.zip` de 0.1.0 com `ditto -x -k`, com quarentena aplicada manualmente (`xattr -w com.apple.quarantine "0083;<data em hexadecimal>;Safari;" MicBoost.app`), sem abrir o app. O app não foi executado e a cópia foi apagada depois da coleta.

| Verificação | Saída |
|---|---|
| `spctl --assess --type execute -vv MicBoost.app` | `MicBoost.app: rejected`, código 3, sem motivo na saída |
| `syspolicy_check distribution MicBoost.app` | falha (código 70): aviso "Adhoc Signed App" e erro fatal "Notary Ticket Missing" |
| `codesign -dv --verbose=4 MicBoost.app` | `Format=app bundle with Mach-O universal (x86_64 arm64)`, `Signature=adhoc`, `TeamIdentifier=not set` |
| `codesign --verify --strict --deep MicBoost.app` | passa (código 0) |
| `log show` de `syspolicyd` durante a avaliação | assinatura verificada (`SecKeyVerifySignature`), `Error checking with notarization daemon: 3`, `rejecting due to lack of matching active rule` |

Interpretação: a rejeição vem da falta de notarização e de Developer ID, não de bundle danificado — a assinatura ad hoc, o selo de recursos e a verificação estrita passam, e o `syspolicyd` rejeita por política ("lack of matching active rule"). O caso esperado na GUI é o de desenvolvedor não identificado, com "Abrir Mesmo Assim" em Ajustes do Sistema → Privacidade e Segurança. O `spctl` não reproduz a interface, então o painel, o botão e o fluxo do Homebrew continuam exigindo confirmação manual em um Mac de teste.

## BlackHole no download direto

- O `.zip` contém só o app. A instalação do BlackHole é instruída à parte: `brew install --cask blackhole-2ch` ou o instalador oficial do upstream.
- Uma variante com o app + o `.pkg` upstream intacto do BlackHole 2ch (duas ações de instalação) **só** é publicada depois de:
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

`README.md` na raiz, em inglês, é a página pública do projeto. O leitor é um usuário sem conhecimento técnico: o texto fala de uso e resultado, em linguagem simples, sem jargão de áudio ou de implementação (agregado, IOProc, dBFS, drift, taxa de amostragem, CLI). Detalhe técnico fica em `docs/` e numa seção curta no fim para desenvolvedores.

Estrutura, nesta ordem:
1. **Cabeçalho:** imagem centralizada com o ícone e o nome "MicBoost", nas variantes clara e escura (`<picture>` com `prefers-color-scheme`), em `docs/design/readme/header-{light,dark}.png`, gerada por `scripts/render-readme-header.sh` a partir das prévias do ícone.
2. Título, badges (macOS 14+, Apple Silicon + Intel, licença GPL-3.0, Sponsor) e uma frase do benefício, citando apps de chamada conhecidos.
3. Callout `> [!NOTE]`: o projeto é desenvolvido e mantido com ajuda de agentes de IA, sob direção e revisão do mantenedor. O README não fala de status, validação ou etapas; isso fica em [roadmap.md](roadmap.md).
4. **What it does:** benefícios em linguagem simples, seguidos da captura do menu com o EQ aberto (`eq-*.png`), centralizada, com legenda abaixo.
5. **What you need** e **Install:** passos numerados: instalar o BlackHole (instalador do site; Homebrew como alternativa), baixar o `.zip` das releases, arrastar para Aplicativos, primeira abertura com "Abrir Mesmo Assim" ([Primeira abertura](#primeira-abertura-sem-notarização), sem `xattr` nem remoção de quarentena) e permissão de microfone. O tap só entra depois de validado.
6. **How to use:** passos numerados (ícone, microfone, chave, escolher "BlackHole 2ch" ou o padrão no app de chamada, ajustar o slider pela barra de saída e pelo selo do limitador), seguidos da captura dos ajustes (`settings-*.png`) com legenda.
7. **Good to know** (ruído junto com o ganho, Bluetooth, iPhone, tampa fechada, abrir ao iniciar sessão, verificação de atualizações e como desligá-la), **Something's wrong?** (perguntas e respostas curtas), **Uninstall**, **Support** (GitHub Sponsors e Buy Me a Coffee), **For developers** (um parágrafo, link para `docs/` e comandos de build), **License**, **Credits** (BlackHole e as referências, deixando claro que é uma implementação independente).

As capturas são do próprio menu composto pelo WindowServer — o auxiliar abre o mesmo `NSMenu` do app com estado de exemplo e o captura com ScreenCaptureKit — e da janela de ajustes real, geradas por `scripts/render-screenshots.sh` em `docs/screenshots/`, com as variantes clara e escura em `<picture>`.

Manutenção: toda mudança visível ao usuário (recurso, instalação, limitação) atualiza o README na mesma mudança; medições ficam em `docs/testing.md`. As capturas são regeneradas quando a UI muda. O cabeçalho é regenerado por `scripts/render-readme-header.sh`, que executa `design/readme/RenderHeader.swift` sobre as prévias do ícone e regrava `docs/design/readme/header-{light,dark}.png`.

## Página do produto

`https://www.vitormach.dev/micboost/` é a página pública do MicBoost para busca e compartilhamento. Fica no repositório do site pessoal do mantenedor (`vittau/vittau.github.io`, Jekyll no GitHub Pages, publicado a partir de `master`) e segue o `DESIGN.md` e o `CLAUDE.md` daquele repositório: mesmos tokens de cor, fontes auto-hospedadas, sem framework, sem CDN e sem dependência em runtime além do GA4 que o site já usa.

- **Idioma e público:** inglês, para o mesmo leitor do README (sem jargão de áudio ou de implementação). O README continua sendo a fonte do texto: a página resume os mesmos benefícios, requisitos, instalação e perguntas, e uma mudança visível ao usuário atualiza os dois.
- **Conteúdo:** ícone e nome; frase de benefício com as buscas comuns ("make your microphone louder on Mac", "increase mic volume", Zoom, Teams, Meet, Discord); botão de download para `https://github.com/vittau/MicBoost/releases/latest`; capturas do painel e dos ajustes (cópias de `docs/screenshots/`, claras e escuras); o que o app faz; requisitos (macOS 14+, BlackHole 2ch); instalação e primeira abertura sem notarização, como no README; perguntas frequentes; links para o repositório, as releases e o apoio; licença GPL-3.0.
- **SEO:** `<title>` e `meta description` próprios, `link rel="canonical"`, Open Graph e Twitter Card com uma imagem 1200 × 630 da página, JSON-LD `SoftwareApplication` (`operatingSystem: macOS 14+`, `applicationCategory: UtilitiesApplication`, `offers.price: 0`), um único `<h1>`, textos alternativos nas imagens, e a URL no `sitemap.txt` do site.
- **Versão:** a página não fixa número de versão; o download aponta sempre para a última release.
- O repositório do MicBoost aponta para a página no campo "Website" do GitHub.

## Licenciamento

O MicBoost é licenciado sob a GPL-3.0 (`LICENSE` na raiz, texto integral da FSF). O motivo é o copyleft: versões derivadas distribuídas precisam continuar abertas. O MicBoost não incorpora código do BlackHole; ele o usa como dispositivo Core Audio, e a licença do BlackHole não condiciona a do MicBoost. A redistribuição do instalador do BlackHole está sujeita às regras acima.
