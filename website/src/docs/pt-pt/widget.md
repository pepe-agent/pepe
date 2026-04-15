---
title: Widget incorporável
description: Coloca uma bolha de chat em qualquer site, ligada a um agente do Pepe.
---

## Widget incorporável

O widget é uma bolha de chat que colocas em qualquer página com uma única tag
`<script>`. Renderiza um botão flutuante, abre num painel de chat e fala com
um agente do Pepe através de uma ligação ao vivo, com streaming, sem
dependências e sem passo de build na página que o incorpora.

### Cria um token de widget

A tag `<script>` de um widget fica no código-fonte público da página, por
isso precisa do seu próprio tipo de token: sempre fixado a um agente, e
ligado à origem do site.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` exige `--agent`: uma credencial pública fixa-se sempre a um agente
conhecido e seguro, nunca a uma empresa inteira ou ao âmbito raiz.
`--allowed-origin` é o esquema e o host do site; a ligação do widget é
recusada a partir de qualquer outro lugar. Consulta [Autenticação e
tokens](./auth/) para o modelo geral de tokens em que isto assenta.

### Ou fá-lo a partir do painel

A secção Channels tem um botão **+ Widget** que abre logo ali um formulário -
rótulo, agente, origem permitida e aparência - sem teres de ir à parte à
página de tokens. Depois de criares um, o painel mostra a tag `<script>`
completa já preenchida com o token real, o agente e o endereço do teu
próprio servidor, pronta a copiar e colar. Os widgets existentes também
mantêm um excerto recolhível, e o token em bruto deles fica visível a
qualquer momento - ao contrário de um token de API normal, o valor de um
token de widget não é um segredo que valha a pena esconder (consulta
[Segurança](#segurança) mais abaixo), por isso não há aquele "copia agora,
não voltas a vê-lo". Mudar que agente ou origem um widget usa continua a
significar criar um novo e revogar o antigo (isso continua a ser só por
rotação), mas a aparência pode ser editada no lugar a qualquer momento.

### Define o aspeto a partir do painel

Título, logo, cor, tema, saudação e posição não têm de viver na tag
`<script>` de todo - define-os no token do widget em vez disso (na criação,
ou depois pelo botão **Edit appearance** num widget existente) e o script
obtém-nos ao carregar. A prioridade é por campo, não tudo-ou-nada: **o valor
do token vence sempre que estiver definido**; um campo por definir no token
cai para o próprio atributo `data-*` da tag, e depois para a predefinição
incorporada. Por isso isto é totalmente opcional (uma incorporação simples
só com `data-token` continua a funcionar exatamente como antes), e os dois
podem misturar-se livremente - cor a vir do painel, saudação fixa na tag,
por exemplo. A ideia é que um ajuste de cor ou saudação nunca precise de um
novo deploy do site: muda no painel, recarrega a página, pronto.

### Incorpora-o

Cola a tag script na página, apontando para o teu servidor Pepe:

```html
<script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
        data-agent="support"
        data-token="pepe_your_widget_token"
        data-title="Chat"
        data-logo="https://example.com/logo.png"
        data-color="#ea580c"
        data-theme="dark"
        data-greeting="Hi! How can I help?"
        data-position="right"></script>
```

| Atributo | O que faz | Predefinição |
|---|---|---|
| `data-agent` | Que agente responde. Tem de coincidir com o agente do próprio token. | `default` |
| `data-token` | O token de widget de `token add --widget`. | nenhum |
| `data-server` | O host a que ligar. | o próprio host do script |
| `data-title` | O texto do cabeçalho do painel. | "Chat" |
| `data-logo` | Uma imagem quadrada pequena, usada como ícone da bolha e junto ao título do cabeçalho. Omite-a para manter a bolha com o emoji simples. | nenhum |
| `data-color` | Cor de destaque da bolha, do cabeçalho e dos botões. | `#ea580c` |
| `data-theme` | `dark` ou `light` - as cores base do painel abaixo do cabeçalho. | `dark` |
| `data-greeting` | A primeira mensagem mostrada antes de o visitante enviar algo. | "Hi! How can I help?" |
| `data-position` | `left` ou `right`. | `right` |

Sem passo de build, sem instalar npm: o `widget.js` e a sua folha de estilo
são servidos diretamente pelo teu servidor Pepe em
`/plugin-assets/pepe-widget/`, a mesma rota genérica que qualquer asset
estático de um futuro plugin usaria.

### Como funciona a sessão de um visitante

Cada visitante recebe um id aleatório, guardado no `localStorage` do
navegador, enviado como a sessão da ligação para que recarregar a página
continue a mesma conversa. Por baixo, o widget fala o mesmo protocolo
descrito em [WebSocket](./websocket/): `prompt` a entrar, `delta` / `done` /
`error` / `watch` a sair.

O botão 🧹 no cabeçalho começa uma conversa nova de imediato: fecha a ligação
actual, limpa o painel e religa com um id de sessão novo. Esse id fica
guardado logo ali, por isso mesmo um reload completo da página continua a
falar com a conversa nova, não com a anterior.

Na página Chat do painel, as conversas do widget agrupam-se em **Widget**,
um subgrupo por site (o `allowed_origin` do token) - assim, teres mais do
que um widget em sites diferentes mantém as conversas fáceis de distinguir,
separadas do chat próprio do painel.

### Segurança

- **Vinculado à origem.** O WebSocket só aceita uma ligação de widget cujo
  `Origin` do navegador coincida com o `allowed_origin` de algum token de
  widget registado (ou com o host do teu próprio servidor). Uma cópia do
  script colada num site não registado é recusada antes de conseguir chegar
  ao agente.
- **Fixado a um agente.** Um token de widget corre sempre exatamente o
  agente para o qual foi criado; o widget não tem forma de pedir outro
  diferente.
- **Com limite de taxa.** As mensagens através de uma ligação de widget são
  limitadas (20 por minuto por predefinição, ajustável com `config :pepe,
  widget_rate_limit:` / `widget_rate_window_s:` se te auto-alojares e
  precisares de ajustar), para que um token público que vive no código-fonte
  da página não possa ser martelado. Nenhuma outra superfície é afetada.
- **Não é tratado como segredo.** O valor em bruto de um token de widget já
  vive em HTML público, legível com "ver código-fonte" no site que o
  incorpora - por isso, ao contrário de um token de API normal, é guardado
  recuperável e continua visível no painel/`manage_token list`. O que
  realmente o protege são os três pontos acima, não esconder a cadeia.

<div class="note"><strong>Dá-lhe um agente restrito.</strong> Um widget fica
exposto à internet pública sem nenhum humano a aprovar chamadas de
ferramenta. Vincula-o a um agente limitado a ferramentas seguras, só de
leitura ou voltadas para o cliente, a mesma orientação de qualquer canal
voltado para o cliente em <a href="./security/">Segurança e ambiente
isolado</a>.</div>

### Fá-lo por chat

Um agente com a ferramenta `manage_token` pode criar um token de widget numa
conversa:

> Cria um token de widget para o agente support, permitido a partir de https://example.com.

O agente chama `manage_token` com `action: "create"`, `agent: "support"`,
`widget: true`, e `allowed_origin: "https://example.com"`. Criar um token não
é só de leitura, por isso a chamada passa pela barreira de permissão; o
token em bruto volta uma vez na resposta para colares na tag script.
