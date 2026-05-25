---
title: Widget incorporável
description: Coloque uma bolha de chat em qualquer site, conectada a um agente do Pepe.
---

## Widget incorporável

O widget é uma bolha de chat que você coloca em qualquer página com uma única
tag `<script>`. Ele renderiza um botão flutuante, abre em um painel de chat e
conversa com um agente do Pepe por uma conexão ao vivo, com streaming, sem
dependência e sem passo de build na página que o incorpora.

<img class="doc-shot" src="/screenshots/widget-pt-br.png" alt="O painel do widget no meio de uma conversa, respondendo em português" />

### Crie um token de widget

A tag `<script>` de um widget fica no código-fonte público da página, então
ela precisa de um tipo próprio de token: sempre travado em um agente, e
vinculado à origem do site.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` exige `--agent`: uma credencial pública sempre se fixa em um agente
conhecido e seguro, nunca em um projeto inteiro.
`--allowed-origin` é o esquema e o host do site; a conexão do widget é
recusada de qualquer outro lugar. Veja [Autenticação e tokens](../auth/) para o
modelo geral de tokens sobre o qual isso se apoia.

### Ou faça pelo painel

A seção Channels tem um botão **+ Widget** que abre um formulário ali mesmo:
rótulo, agente, origem permitida e aparência, sem precisar ir até a página
de tokens. Depois de criar um, o painel mostra a tag `<script>` completa já
preenchida com o token real, o agente e o endereço do seu próprio servidor,
pronta para copiar e colar. Widgets existentes também mantêm um trecho
recolhível, e o token bruto deles fica visível a qualquer momento. Diferente
de um token de API normal, o valor de um token de widget não é um segredo
que vale a pena esconder (veja [Segurança](#segurança) mais abaixo), então
não tem aquele "copie agora, você não vai ver de novo". Trocar qual agente
ou origem um widget usa ainda significa criar um novo e revogar o antigo
(esses dois continuam sendo apenas rotacionáveis), mas a aparência pode ser
editada no lugar a qualquer momento.

### Defina a aparência pelo painel

Título, logo, cor, tema, saudação e posição não precisam morar na tag
`<script>` de jeito nenhum: defina no token do widget em vez disso (na
criação, ou depois pelo botão **Edit appearance** num widget existente) e o
script busca isso ao carregar. A prioridade é por campo, não tudo-ou-nada:
**o valor do token prevalece sempre que estiver definido**; um campo não
definido no token recorre ao atributo `data-*` da tag, e depois ao
padrão embutido. Então isso é totalmente opcional (uma incorporação simples
só com `data-token` continua funcionando exatamente como antes), e os dois
podem se misturar livremente: cor vindo do painel, saudação fixa na tag,
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
        data-greeting="Olá! Como posso ajudar?"
        data-position="right"
        data-lang="pt-BR"></script>
```

| Atributo | O que faz | Padrão |
|---|---|---|
| `data-agent` | Só cosmético: nomeia a sessão local do visitante para que mais de um widget consiga dividir a mesma página sem conflito. Um token de widget sempre é travado num agente, então isso nunca muda quem responde de fato. | `default` |
| `data-token` | O token de widget de `token add --widget`. | nenhum |
| `data-server` | O host para conectar. | o próprio host do script |
| `data-title` | O texto do cabeçalho do painel. | "Chat" |
| `data-logo` | Uma imagem quadrada pequena, usada como ícone da bolha e ao lado do título no cabeçalho. Omita para manter o ícone de chat simples. | nenhum |
| `data-color` | Cor de destaque da bolha, do cabeçalho e dos botões. | `#ea580c` |
| `data-theme` | `light` ou `dark`: as cores base do painel abaixo do cabeçalho. | `light` |
| `data-greeting` | A primeira mensagem mostrada antes de o visitante enviar algo. | escolhida a partir de `data-lang`, inglês se nenhum for definido |
| `data-position` | `left` ou `right`. | `right` |
| `data-lang` | O idioma **do site**, não o do navegador do visitante (ex.: `pt-BR`). Um site sabe em que idioma ele foi escrito, um locale de navegador é só um chute sobre quem está lendo. Escolhe a saudação embutida quando `data-greeting` não é definido, e é enviado uma vez ao entrar na conversa para que o agente já se incline a responder nesse idioma desde a primeira resposta. | nenhum |

Sem passo de build, sem instalar npm: `widget.js` e sua folha de estilo são
servidos diretamente pelo seu servidor Pepe em `/plugin-assets/pepe-widget/`,
a mesma rota genérica que qualquer asset estático de um futuro plugin usaria.

### Como funciona a sessão de um visitante

Cada visitante recebe um id aleatório, guardado no `localStorage` do
navegador, enviado como a sessão da conexão para que recarregar a página
continue a mesma conversa. Por baixo dos panos, o widget fala o mesmo
protocolo descrito em [WebSocket](../websocket/): `prompt` de entrada, `delta`
/ `done` / `error` / `watch` / `session_ended` de saída. Um indicador de
pontinhos saltitantes aparece no painel enquanto o agente prepara uma
resposta, então o visitante nunca fica em dúvida se a mensagem foi enviada.

O botão de nova conversa no cabeçalho (um simples "+") começa uma conversa
nova na hora: fecha a conexão atual, limpa o painel e reconecta com um id de
sessão novo. Esse id já fica salvo na hora, então mesmo um reload completo da
página continua falando com a conversa nova, não com a antiga. Se o próprio
agente encerrar a conversa (a ferramenta `end_session` dele), o painel mostra uma
pequena nota do sistema no lugar, e a próxima mensagem que você mandar já
começa do zero, sem precisar clicar em nada.

<div class="note"><strong>Sem comandos de barra.</strong> O widget fala o
protocolo de streaming acima, não uma sessão de chat completa: não tem
<code>/model</code>, <code>/models</code> nem nenhum outro comando de barra,
só os controles do próprio painel. Um widget fica sempre preso ao modelo do
próprio agente; para oferecer um modelo diferente a um visitante, gere um
token de widget separado para um agente já configurado com esse modelo.</div>

Na página Chat do painel, conversas do widget se agrupam em **Widget**, um
subgrupo por site (o `allowed_origin` do token): assim, ter mais de um
widget em sites diferentes mantém as conversas fáceis de distinguir,
separadas do chat próprio do painel.

### Segurança

- **Vinculado à origem.** Um navegador que se conecta com um token de widget
  específico é recusado a menos que o `Origin` dele bata com o
  `allowed_origin` desse mesmo token (ou com o host do seu próprio
  servidor). Uma cópia do script colada em um site não registrado é
  recusada antes de conseguir chegar ao agente, e um token vazado também não
  pode ser reutilizado a partir de outro site, mesmo um para o qual esse
  mesmo servidor sirva outro widget.
- **Travado em um agente.** Um token de widget sempre roda exatamente o
  agente para o qual foi criado; o widget não tem como pedir outro diferente.
- **Com limite de taxa.** As mensagens por uma conexão de widget são
  limitadas (20 por minuto por padrão, ajustável com `config :pepe,
  widget_rate_limit:` / `widget_rate_window_s:` se você se auto-hospeda e
  precisa ajustar), para que um token público que vive no código-fonte da
  página não possa ser bombardeado. Nenhuma outra superfície é afetada.
- **Não é tratado como segredo.** O valor bruto de um token de widget já
  mora em HTML público, legível com "exibir código-fonte" no site que o
  incorpora. Então, diferente de um token de API normal, ele é guardado
  recuperável e continua visível no painel/`manage_token list`. O que
  realmente o protege são os três pontos acima, não esconder a string.

<div class="note"><strong>Dê um agente restrito.</strong> Um widget fica de
exposto à internet pública, sem nenhum humano aprovando chamadas de
ferramenta. Vincule-o a um agente limitado a ferramentas seguras, somente
leitura ou voltadas ao cliente, a mesma orientação de qualquer canal voltado
ao cliente em <a href="./security/">Segurança e ambiente isolado</a>.</div>

### Faça por chat

Um agente com a ferramenta `manage_token` pode criar um token de widget numa
conversa:

> Crie um token de widget para o agente support, permitido a partir de https://example.com.

O agente chama `manage_token` com `action: "create"`, `agent: "support"`,
`widget: true`, e `allowed_origin: "https://example.com"`. Criar um token não
é somente leitura, então a chamada passa pela barreira de permissão; o token
bruto volta na resposta para você copiar na tag script, e continua disponível
a qualquer momento com `action: "list"`, já que um token de widget não é um
segredo que vale a pena esconder.

A aparência funciona do mesmo jeito, em qualquer uma das duas ações: passe
qualquer um de `title`, `logo`, `color`, `theme`, `greeting`, `position` no
`create`, ou depois com `action: "update"` e o `id` do token:

> Muda a saudação do widget do support para "Oi! Precisa de ajuda?" e a cor para #2563eb.

O agente chama `manage_token` com `action: "update"`, `id: "<o id do
token>"`, `greeting: "Oi! Precisa de ajuda?"`, e `color: "#2563eb"`; um
campo deixado de fora da chamada mantém o valor atual.
