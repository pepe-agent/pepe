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

### Incorpora-o

Cola a tag script na página, apontando para o teu servidor Pepe:

```html
<script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
        data-agent="support"
        data-token="ctx_your_widget_token"
        data-color="#ea580c"
        data-greeting="Hi! How can I help?"
        data-position="right"></script>
```

| Atributo | O que faz | Predefinição |
|---|---|---|
| `data-agent` | Que agente responde. Tem de coincidir com o agente do próprio token. | `default` |
| `data-token` | O token de widget de `token add --widget`. | nenhum |
| `data-server` | O host a que ligar. | o próprio host do script |
| `data-color` | Cor de destaque da bolha e dos botões. | `#ea580c` |
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
