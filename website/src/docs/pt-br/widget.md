---
title: Widget incorporável
description: Coloque uma bolha de chat em qualquer site, conectada a um agente do Pepe.
---

## Widget incorporável

O widget é uma bolha de chat que você coloca em qualquer página com uma única
tag `<script>`. Ele renderiza um botão flutuante, abre em um painel de chat e
conversa com um agente do Pepe por uma conexão ao vivo, com streaming, sem
dependência e sem passo de build na página que o incorpora.

### Crie um token de widget

A tag `<script>` de um widget fica no código-fonte público da página, então
ela precisa de um tipo próprio de token: sempre travado em um agente, e
vinculado à origem do site.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` exige `--agent`: uma credencial pública sempre se fixa em um agente
conhecido e seguro, nunca em uma empresa inteira ou no escopo raiz.
`--allowed-origin` é o esquema e o host do site; a conexão do widget é
recusada de qualquer outro lugar. Veja [Autenticação e tokens](./auth/) para o
modelo geral de tokens sobre o qual isso se apoia.

### Ou faça pelo painel

A seção Channels tem um botão **+ Widget** que abre um formulário ali mesmo -
rótulo, agente, origem permitida e aparência - sem precisar ir até a página
de tokens. Depois de criar um, o painel mostra a tag `<script>` completa já
preenchida com o token real, o agente e o endereço do seu próprio servidor,
pronta pra copiar e colar. Widgets existentes também mantêm um trecho
recolhível, e o token bruto deles fica visível a qualquer momento - diferente
de um token de API normal, o valor de um token de widget não é um segredo
que vale a pena esconder (veja [Segurança](#segurança) mais abaixo), então
não tem aquele "copie agora, você não vai ver de novo". Trocar qual agente
ou origem um widget usa ainda significa criar um novo e revogar o antigo
(isso continua só por rotação), mas a aparência pode ser editada no lugar a
qualquer momento.

### Defina a aparência pelo painel

Título, logo, cor, tema, saudação e posição não precisam morar na tag
`<script>` de jeito nenhum - defina no token do widget em vez disso (na
criação, ou depois pelo botão **Edit appearance** num widget existente) e o
script busca isso ao carregar. A prioridade é por campo, não tudo-ou-nada:
**o valor do token vence sempre que estiver definido**; um campo não
definido no token cai pro próprio atributo `data-*` da tag, e depois pro
padrão embutido. Então isso é totalmente opcional (uma incorporação simples
só com `data-token` continua funcionando exatamente como antes), e os dois
podem se misturar livremente - cor vindo do painel, saudação fixa na tag,
por exemplo. A ideia é que um ajuste de cor ou saudação nunca precise de um
novo deploy do site: muda no painel, recarrega a página, pronto.

### Incorpore

Cole a tag script na página, apontando para o seu servidor Pepe:

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

| Atributo | O que faz | Padrão |
|---|---|---|
| `data-agent` | Qual agente responde. Precisa bater com o agente do próprio token. | `default` |
| `data-token` | O token de widget de `token add --widget`. | nenhum |
| `data-server` | O host para conectar. | o próprio host do script |
| `data-title` | O texto do cabeçalho do painel. | "Chat" |
| `data-logo` | Uma imagem quadrada pequena, usada como ícone da bolha e ao lado do título no cabeçalho. Omita pra manter a bolha com o emoji simples. | nenhum |
| `data-color` | Cor de destaque da bolha, do cabeçalho e dos botões. | `#ea580c` |
| `data-theme` | `dark` ou `light` - as cores base do painel abaixo do cabeçalho. | `dark` |
| `data-greeting` | A primeira mensagem mostrada antes de o visitante enviar algo. | "Hi! How can I help?" |
| `data-position` | `left` ou `right`. | `right` |

Sem passo de build, sem instalar npm: `widget.js` e sua folha de estilo são
servidos diretamente pelo seu servidor Pepe em `/plugin-assets/pepe-widget/`,
a mesma rota genérica que qualquer asset estático de um futuro plugin usaria.

### Como funciona a sessão de um visitante

Cada visitante recebe um id aleatório, guardado no `localStorage` do
navegador, enviado como a sessão da conexão para que recarregar a página
continue a mesma conversa. Por baixo dos panos, o widget fala o mesmo
protocolo descrito em [WebSocket](./websocket/): `prompt` de entrada, `delta`
/ `done` / `error` / `watch` de saída.

O botão 🧹 no cabeçalho começa uma conversa nova na hora: fecha a conexão
atual, limpa o painel e reconecta com um id de sessão novo. Esse id já fica
salvo na hora, então mesmo um reload completo da página continua falando com
a conversa nova, não com a antiga.

Na página Chat do painel, conversas do widget se agrupam em **Widget**, um
subgrupo por site (o `allowed_origin` do token) - assim, ter mais de um
widget em sites diferentes mantém as conversas fáceis de distinguir,
separadas do chat próprio do painel.

### Segurança

- **Vinculado à origem.** O WebSocket só aceita uma conexão de widget cujo
  `Origin` do navegador bata com o `allowed_origin` de algum token de widget
  registrado (ou com o host do seu próprio servidor). Uma cópia do script
  colada em um site não registrado é recusada antes de conseguir chegar ao
  agente.
- **Travado em um agente.** Um token de widget sempre roda exatamente o
  agente pro qual foi criado; o widget não tem como pedir outro diferente.
- **Com limite de taxa.** As mensagens por uma conexão de widget são
  limitadas (20 por minuto por padrão, ajustável com `config :pepe,
  widget_rate_limit:` / `widget_rate_window_s:` se você se auto-hospeda e
  precisa ajustar), pra que um token público que vive no código-fonte da
  página não possa ser bombardeado. Nenhuma outra superfície é afetada.
- **Não é tratado como segredo.** O valor bruto de um token de widget já
  mora em HTML público, legível com "exibir código-fonte" no site que o
  incorpora - então, diferente de um token de API normal, ele é guardado
  recuperável e continua visível no painel/`manage_token list`. O que
  realmente protege ele são os três pontos acima, não esconder a string.

<div class="note"><strong>Dê um agente restrito.</strong> Um widget fica de
cara pra internet pública, sem nenhum humano aprovando chamadas de
ferramenta. Vincule-o a um agente limitado a ferramentas seguras, somente
leitura ou voltadas ao cliente, a mesma orientação de qualquer canal voltado
ao cliente em <a href="./security/">Segurança e ambiente isolado</a>.</div>

### Faça por chat

Um agente com a tool `manage_token` pode criar um token de widget numa
conversa:

> Crie um token de widget para o agente support, permitido a partir de https://example.com.

O agente chama `manage_token` com `action: "create"`, `agent: "support"`,
`widget: true`, e `allowed_origin: "https://example.com"`. Criar um token não
é somente leitura, então a chamada passa pela barreira de permissão; o token
bruto volta na resposta pra você copiar na tag script - e continua disponível
a qualquer momento com `action: "list"`, já que um token de widget não é um
segredo que vale a pena esconder.

A aparência funciona do mesmo jeito, em qualquer uma das duas ações: passe
qualquer um de `title`, `logo`, `color`, `theme`, `greeting`, `position` no
`create`, ou depois com `action: "update"` e o `id` do token:

> Muda a saudação do widget do support pra "Oi! Precisa de ajuda?" e a cor pra #2563eb.

O agente chama `manage_token` com `action: "update"`, `id: "<o id do
token>"`, `greeting: "Oi! Precisa de ajuda?"`, e `color: "#2563eb"` - um
campo deixado de fora da chamada mantém o valor atual.
