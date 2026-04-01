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

### Incorpore

Cole a tag script na página, apontando para o seu servidor Pepe:

```html
<script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
        data-agent="support"
        data-token="ctx_your_widget_token"
        data-color="#ea580c"
        data-greeting="Hi! How can I help?"
        data-position="right"></script>
```

| Atributo | O que faz | Padrão |
|---|---|---|
| `data-agent` | Qual agente responde. Precisa bater com o agente do próprio token. | `default` |
| `data-token` | O token de widget de `token add --widget`. | nenhum |
| `data-server` | O host para conectar. | o próprio host do script |
| `data-color` | Cor de destaque da bolha e dos botões. | `#ea580c` |
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
bruto volta uma vez na resposta pra você copiar na tag script.
