---
title: Widget incorporável
description: Coloca uma bolha de chat em qualquer site, ligada a um agente do Pepe.
---

## Widget incorporável

O widget é uma bolha de chat que colocas em qualquer página com uma única tag
`<script>`. Renderiza um botão flutuante, abre num painel de chat e fala com
um agente do Pepe através de uma ligação ao vivo, com streaming, sem
dependências e sem passo de build na página que o incorpora.

<img class="doc-shot" src="/screenshots/widget-pt-pt.png" alt="O painel do widget a meio de uma conversa, a responder em português" />

### Cria um token de widget

A tag `<script>` de um widget fica no código-fonte público da página, por
isso precisa do seu próprio tipo de token: sempre fixado a um agente, e
ligado à origem do site.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` exige `--agent`: uma credencial pública fixa-se sempre a um agente
conhecido e seguro, nunca a um projeto inteiro ou ao projeto default.
`--allowed-origin` é o esquema e o host do site; a ligação do widget é
recusada a partir de qualquer outro lugar. Consulta [Autenticação e
tokens](../auth/) para o modelo geral de tokens em que isto assenta.

### Ou fá-lo a partir do painel

A secção Channels tem um botão **+ Widget** que abre logo ali um formulário:
rótulo, agente, origem permitida e aparência, sem teres de ir à parte à
página de tokens. Depois de criares um, o painel mostra a tag `<script>`
completa já preenchida com o token real, o agente e o endereço do teu
próprio servidor, pronta a copiar e colar. Os widgets existentes também
mantêm um excerto recolhível, e o token em bruto deles fica visível a
qualquer momento. Ao contrário de um token de API normal, o valor de um
token de widget não é um segredo que valha a pena esconder (consulta
[Segurança](#segurança) mais abaixo), por isso não há aquele "copia agora,
não voltas a vê-lo". Mudar que agente ou origem um widget usa continua a
significar criar um novo e revogar o antigo (isso continua a ser só por
rotação), mas a aparência pode ser editada no lugar a qualquer momento.

### Define o aspeto a partir do painel

Título, logo, cor, tema, saudação e posição não têm de viver na tag
`<script>` de todo: define-os no token do widget em vez disso (na criação,
ou depois pelo botão **Edit appearance** num widget existente) e o script
obtém-nos ao carregar. A prioridade é por campo, não tudo-ou-nada: **o valor
do token vence sempre que estiver definido**; um campo por definir no token
cai para o próprio atributo `data-*` da tag, e depois para a predefinição
incorporada. Por isso isto é totalmente opcional (uma incorporação simples
só com `data-token` continua a funcionar exatamente como antes), e os dois
podem misturar-se livremente (cor a vir do painel, saudação fixa na tag,
por exemplo). A ideia é que um ajuste de cor ou saudação nunca precise de um
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
        data-greeting="Olá! Em que posso ajudar?"
        data-position="right"
        data-lang="pt-PT"></script>
```

| Atributo | O que faz | Predefinição |
|---|---|---|
| `data-agent` | Só cosmético: nomeia a sessão local do visitante para que mais do que um widget consiga partilhar a mesma página sem conflito. Um token de widget está sempre bloqueado a um agente, por isso isto nunca muda quem responde de facto. | `default` |
| `data-token` | O token de widget de `token add --widget`. | nenhum |
| `data-server` | O host a que ligar. | o próprio host do script |
| `data-title` | O texto do cabeçalho do painel. | "Chat" |
| `data-logo` | Uma imagem quadrada pequena, usada como ícone da bolha e junto ao título do cabeçalho. Omite-a para manter o ícone de chat simples. | nenhum |
| `data-color` | Cor de destaque da bolha, do cabeçalho e dos botões. | `#ea580c` |
| `data-theme` | `light` ou `dark`: as cores base do painel abaixo do cabeçalho. | `light` |
| `data-greeting` | A primeira mensagem mostrada antes de o visitante enviar algo. | escolhida a partir de `data-lang`, inglês se nenhum estiver definido |
| `data-position` | `left` ou `right`. | `right` |
| `data-lang` | O idioma **do site**, não o do navegador do visitante (p. ex. `pt-PT`). Um site sabe em que idioma foi escrito, um locale de navegador é só um palpite sobre quem o está a ler. Escolhe a saudação incorporada quando `data-greeting` não está definido, e é enviado uma vez ao entrar na conversa, para que o agente já se incline a responder nesse idioma desde a sua primeira resposta. | nenhum |

Sem passo de build, sem instalar npm: o `widget.js` e a sua folha de estilo
são servidos diretamente pelo teu servidor Pepe em
`/plugin-assets/pepe-widget/`, a mesma rota genérica que qualquer asset
estático de um futuro plugin usaria.

### Como funciona a sessão de um visitante

Cada visitante recebe um id aleatório, guardado no `localStorage` do
navegador, enviado como a sessão da ligação para que recarregar a página
continue a mesma conversa. Por baixo, o widget fala o mesmo protocolo
descrito em [WebSocket](../websocket/): `prompt` a entrar, `delta` / `done` /
`error` / `watch` / `session_ended` a sair. Um indicador de pontinhos a saltar
aparece no painel enquanto o agente prepara uma resposta, para o visitante
nunca ficar em dúvida se a mensagem foi enviada.

O botão de nova conversa no cabeçalho (um simples "+") começa uma conversa
nova de imediato: fecha a ligação atual, limpa o painel e religa com um id
de sessão novo. Esse id fica guardado logo ali, por isso mesmo um reload
completo da página continua a falar com a conversa nova, não com a anterior.
Se o próprio agente terminar a conversa (a ferramenta `end_session` dele), o
painel mostra uma pequena nota do sistema no lugar, e a próxima mensagem que
enviares já começa do zero, sem seres tu a ter de clicar em nada.

<div class="note"><strong>Sem comandos de barra.</strong> O widget fala o
protocolo de streaming acima, não uma sessão de chat completa: não tem
<code>/model</code>, <code>/models</code> nem qualquer outro comando de
barra, só os controlos próprios do painel. Um widget fica sempre preso ao
modelo do próprio agente; para oferecer um modelo diferente a um visitante,
gera um token de widget separado para um agente já configurado com esse
modelo.</div>

Na página Chat do painel, as conversas do widget agrupam-se em **Widget**,
um subgrupo por site (o `allowed_origin` do token). Assim, teres mais do
que um widget em sites diferentes mantém as conversas fáceis de distinguir,
separadas do chat próprio do painel.

### Segurança

- **Vinculado à origem.** Um navegador que se liga com um token de widget
  específico é recusado a menos que o `Origin` dele coincida com o
  `allowed_origin` desse mesmo token (ou com o host do teu próprio
  servidor). Uma cópia do script colada num site não registado é recusada
  antes de conseguir chegar ao agente, e um token roubado também não pode
  ser reutilizado a partir de outro site, mesmo um para o qual esse mesmo
  servidor sirva outro widget.
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
  incorpora. Por isso, ao contrário de um token de API normal, é guardado
  recuperável e continua visível no painel/`manage_token list`. O que
  realmente o protege são os três pontos acima, não esconder a cadeia.

<div class="note"><strong>Dá-lhe um agente restrito.</strong> Um widget fica
exposto à internet pública sem nenhum humano a aprovar chamadas de
ferramenta. Vincula-o a um agente limitado a ferramentas seguras, só de
leitura ou voltadas para o cliente, a mesma orientação de qualquer canal
voltado para o cliente em <a href="./security/">Segurança e ambiente
isolado</a>.</div>

### Fá-lo pela conversa

Um agente com a ferramenta `manage_token` pode criar um token de widget numa
conversa:

> Cria um token de widget para o agente support, permitido a partir de https://example.com.

O agente chama `manage_token` com `action: "create"`, `agent: "support"`,
`widget: true`, e `allowed_origin: "https://example.com"`. Criar um token não
é só de leitura, por isso a chamada passa pela barreira de permissão; o
token em bruto volta na resposta para colares na tag script, e continua
disponível a qualquer momento com `action: "list"`, já que um token de widget
não é um segredo que valha a pena esconder.

A aparência funciona da mesma forma, em qualquer uma das duas ações: passa
qualquer um de `title`, `logo`, `color`, `theme`, `greeting`, `position` no
`create`, ou depois com `action: "update"` e o `id` do token:

> Muda a saudação do widget do support para "Olá! Precisas de ajuda?" e a cor para #2563eb.

O agente chama `manage_token` com `action: "update"`, `id: "<o id do
token>"`, `greeting: "Olá! Precisas de ajuda?"`, e `color: "#2563eb"`. Um
campo deixado de fora da chamada mantém o valor atual.
