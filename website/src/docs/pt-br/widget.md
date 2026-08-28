---
title: Widget incorporável
description: Coloque uma bolha de chat em qualquer site, ligada a um agente do Pepe.
---

## Widget incorporável

O widget é uma bolha de chat que entra em qualquer página com uma única tag
`<script>`. Ela renderiza um botão flutuante que abre num painel de chat e
fala com um agente do Pepe por uma conexão ao vivo, em streaming, sem
nenhuma dependência nem passo de build na página que o incorpora.

<img class="doc-shot" src="/screenshots/widget-pt-br.png" alt="O painel do widget no meio de uma conversa, respondendo em português" />

### Criando um token de widget

Como a tag `<script>` de um widget fica no código-fonte público da página,
ela pede um tipo próprio de token: sempre travado num único agente, e
vinculado à origem do site.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` exige `--agent` junto, já que uma credencial pública precisa
ficar presa a um agente conhecido e seguro, nunca a um projeto inteiro.
`--allowed-origin` define o esquema e o host do site, e a conexão do widget
é recusada vindo de qualquer outro lugar. Para o modelo geral de tokens por
trás disso tudo, veja [Autenticação e tokens](../auth/).

### Ou direto pelo painel

Na seção Channels existe um botão **+ Widget** que já abre um formulário
ali mesmo (rótulo, agente, origem permitida e aparência), sem precisar sair
para a página de tokens. Depois de criado, o painel mostra a tag `<script>`
inteira, já preenchida com o token real, o agente e o endereço do seu
próprio servidor, pronta para copiar e colar. Widgets já existentes também
guardam um trecho recolhível, com o token bruto sempre visível: diferente
de um token de API comum, o valor de um token de widget não é segredo
nenhum a esconder (veja [Segurança](#segurança) mais abaixo), então não
existe aquele aviso de "copie agora, você não vai ver de novo". Trocar o
agente ou a origem de um widget ainda exige criar um token novo e revogar
o antigo (essa parte continua só-rotação), mas a aparência dá para editar
no lugar, a qualquer momento.

### Definindo a aparência pelo painel

Título, logo, cor, tema, saudação e posição nem precisam morar na tag
`<script>`: dá para definir tudo isso direto no token do widget (na
criação, ou depois pelo botão **Edit appearance** de um widget já
existente), e o script busca esses valores ao carregar. A prioridade é
campo por campo, não tudo-ou-nada: **o valor definido no token sempre
prevalece**; um campo deixado em branco no token cai de volta para o
atributo `data-*` correspondente na tag e, por fim, para o padrão embutido.
Ou seja, isso é totalmente opcional, uma incorporação simples com só
`data-token` continua funcionando exatamente como antes, e os dois métodos
se misturam sem problema: a cor vindo do painel, a saudação fixada direto
na tag, por exemplo. A ideia é simples: um ajuste de cor ou de saudação
nunca deveria exigir um novo deploy do site. Muda no painel, recarrega a
página, e pronto.

### Incorporando

Cole a tag de script na página, apontando para o seu servidor Pepe:

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
| `data-agent` | Puramente cosmético: nomeia a sessão local do visitante, para que mais de um widget consiga conviver na mesma página sem conflito. Um token de widget já vem travado num agente, então este atributo nunca decide quem de fato responde. | `default` |
| `data-token` | O token de widget gerado por `token add --widget`. | nenhum |
| `data-server` | O host ao qual se conectar. | o próprio host do script |
| `data-title` | O texto do cabeçalho do painel. | "Chat" |
| `data-logo` | Uma imagem quadrada pequena, usada como ícone da bolha e ao lado do título no cabeçalho. Sem ela, fica o ícone de chat padrão. | nenhum |
| `data-color` | Cor de destaque da bolha, do cabeçalho e dos botões. | `#ea580c` |
| `data-theme` | `light` ou `dark`, define as cores base do painel abaixo do cabeçalho. | `light` |
| `data-greeting` | A primeira mensagem exibida antes de o visitante enviar qualquer coisa. | escolhida a partir de `data-lang`, ou inglês se nada for definido |
| `data-position` | `left` ou `right`. | `right` |
| `data-lang` | O idioma **do próprio site**, não o do navegador do visitante (por exemplo, `pt-BR`). Um site sabe em que idioma foi escrito; um locale de navegador é apenas um palpite sobre quem está lendo. Esse valor escolhe a saudação embutida quando `data-greeting` não é definido, e é enviado uma vez, logo na entrada, para que o agente já se incline a responder nesse idioma desde a primeira mensagem. | nenhum |

Não existe passo de build nem `npm install`: `widget.js` e sua folha de
estilo são servidos direto pelo seu servidor Pepe em
`/plugin-assets/pepe-widget/`, a mesma rota genérica que qualquer asset
estático de um futuro plugin usaria.

### Como funciona a sessão de um visitante

Cada visitante recebe um id aleatório, guardado no `localStorage` do
navegador e enviado como a sessão da conexão, então recarregar a página
continua a mesma conversa de antes. Por baixo dos panos, o widget fala o
mesmo protocolo descrito em [WebSocket](../websocket/): `prompt` entrando,
`delta`, `done`, `error`, `watch` e `session_ended` saindo. Enquanto o
agente prepara a resposta, um indicador de pontinhos saltitantes aparece no
painel, então o visitante nunca fica na dúvida se a mensagem realmente foi
enviada.

O botão de nova conversa no cabeçalho (um simples "+") já começa uma
conversa nova ali mesmo: fecha a conexão atual, limpa o painel e reconecta
com um id de sessão novinho. Esse id é salvo imediatamente, então até um
reload completo da página continua na conversa nova, não na antiga. Se o
próprio agente encerrar a conversa, pela ferramenta `end_session`, o painel
mostra uma pequena nota do sistema no lugar, e a próxima mensagem enviada
já começa do zero, sem precisar clicar em nada.

<div class="note"><strong>Sem comandos de barra.</strong> O widget usa esse
protocolo de streaming mais simples, não uma sessão de chat completa, então
não existe <code>/model</code>, <code>/models</code> nem qualquer outro
comando de barra, só os controles do próprio painel. Um widget sempre fica
preso ao modelo do agente ao qual está vinculado; para oferecer um modelo
diferente a um visitante, é preciso gerar um token de widget separado para
um agente já configurado com esse outro modelo.</div>

Na página Chat do painel, as conversas do widget se agrupam sob **Widget**,
com um subgrupo por site (o `allowed_origin` de cada token), então manter
vários widgets em sites diferentes não confunde as conversas entre si, nem
com o chat próprio do painel.

### Segurança

- **Vinculado à origem.** Um navegador que tenta se conectar com um token
  de widget é recusado a menos que seu `Origin` bata exatamente com o
  `allowed_origin` daquele token específico (ou com o host do seu próprio
  servidor). Uma cópia do script colada num site não registrado é recusada
  antes mesmo de chegar ao agente, e um token vazado também não pode ser
  reaproveitado a partir de outro site, nem mesmo um para o qual esse
  mesmo servidor sirva outro widget qualquer.
- **Travado num agente.** Um token de widget roda sempre exatamente o
  agente para o qual foi criado; o widget simplesmente não tem como pedir
  um agente diferente.
- **Com limite de taxa.** Prompts enviados por uma conexão de widget têm
  um teto (20 por minuto por padrão, ajustável via `config :pepe,
  widget_rate_limit:` / `widget_rate_window_s:` para quem se auto-hospeda
  e precisa mudar isso), evitando que um token público, exposto no
  código-fonte da página, seja bombardeado de requisições. Nenhuma outra
  superfície é afetada por esse limite.
- **Não tratado como segredo.** O valor bruto de um token de widget já vive
  em HTML público, visível com um simples "exibir código-fonte" no site que
  o incorpora. Por isso, diferente de um token de API comum, ele é
  guardado de forma recuperável e continua visível no painel e no
  `manage_token list`. Quem realmente protege esse token são os três
  pontos acima, não o fato de a string ficar escondida.

<div class="note"><strong>Escolha um agente restrito.</strong> Um widget
fica exposto à internet pública, sem nenhum humano por perto para aprovar
chamadas de ferramenta. Vincule-o a um agente limitado a ferramentas
seguras, de leitura ou voltadas ao cliente, a mesma orientação que vale
para qualquer canal voltado ao cliente, detalhada em <a
href="./security/">Segurança e ambiente isolado</a>.</div>

### Fazendo pela conversa

Um agente com a ferramenta `manage_token` consegue criar um token de widget
direto numa conversa:

> Cria um token de widget para o agente support, liberado a partir de https://example.com.

O agente chama `manage_token` com `action: "create"`, `agent: "support"`,
`widget: true` e `allowed_origin: "https://example.com"`. Como criar um
token não é uma operação somente leitura, a chamada passa pela barreira de
permissão; o token bruto volta na resposta para você copiar direto na tag
de script, e continua acessível a qualquer momento com `action: "list"`,
já que um token de widget não é segredo que precise ficar escondido.

A aparência funciona do mesmo jeito nas duas ações: passe `title`, `logo`,
`color`, `theme`, `greeting` ou `position` já no `create`, ou depois com
`action: "update"` junto do `id` do token:

> Muda a saudação do widget do support para "Oi! Precisa de ajuda?" e a cor para #2563eb.

O agente chama `manage_token` com `action: "update"`, `id: "<o id do
token>"`, `greeting: "Oi! Precisa de ajuda?"` e `color: "#2563eb"`; qualquer
campo deixado de fora da chamada simplesmente mantém o valor que já tinha.
