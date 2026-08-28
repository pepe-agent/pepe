---
title: Widget incorporável
description: Coloca uma bolha de chat em qualquer site, ligada a um único agente do Pepe.
---

## Widget incorporável

O widget é uma bolha de chat que se coloca em qualquer página com uma única tag `<script>`. Renderiza um botão flutuante que se abre num painel de chat, e fala com um agente do Pepe por uma ligação ao vivo, em streaming, sem dependências nem passo de build na página que o incorpora.

<img class="doc-shot" src="/screenshots/widget-pt-pt.png" alt="O painel do widget a meio de uma conversa, a responder em português" />

### Cria um token de widget

Como a tag `<script>` de um widget fica exposta no código-fonte público da página, precisa do seu próprio tipo de token: sempre preso a um único agente, e ligado à origem do site.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` exige `--agent`, porque uma credencial pública tem de estar sempre presa a um agente conhecido e seguro, nunca a um projeto inteiro. `--allowed-origin` indica o esquema e o host do site; a partir de qualquer outro sítio, a ligação do widget é recusada. Para o modelo geral de tokens em que isto se baseia, consulta [Autenticação e tokens](../auth/).

### Ou faz isto pelo painel

A secção Channels tem um botão **+ Widget** que abre logo ali um formulário (rótulo, agente, origem permitida e aparência), sem teres de saltar para a página de tokens à parte. Depois de criado, o painel mostra a tag `<script>` já completa, com o token real, o agente e o endereço do teu próprio servidor preenchidos, pronta a copiar e colar. Os widgets já existentes também guardam um excerto recolhível, e o token em bruto continua visível sempre que precisares; ao contrário de um token de API normal, o valor de um token de widget não é um segredo que valha a pena esconder (vê [Segurança](#segurança) mais abaixo), por isso não há aquele aviso de "copia agora, não voltas a ver". Mudar o agente ou a origem de um widget continua a exigir criar um novo e revogar o antigo, já que isso só se resolve por rotação, mas a aparência pode ser editada no próprio lugar, a qualquer momento.

### Define o aspeto pelo painel

Título, logótipo, cor, tema, saudação e posição nem precisam de viver na tag `<script>`: podes defini-los antes no próprio token do widget (na criação, ou mais tarde através do botão **Edit appearance** de um widget já existente), e o script vai buscá-los ao carregar a página. A prioridade funciona campo a campo, não tudo-ou-nada: **o valor do token vence sempre que estiver definido**, e um campo que fique por definir no token recua para o atributo `data-*` correspondente na tag e, na falta desse, para a predefinição incorporada. Por isso, isto continua totalmente opcional (uma incorporação simples, só com `data-token`, funciona exatamente como antes), e os dois métodos misturam-se sem problema, por exemplo com a cor a vir do painel e a saudação fixa na própria tag. A vantagem é que um ajuste de cor ou de saudação nunca exige um novo deploy do site: muda-se no painel, recarrega-se a página, e está feito.

### Incorpora-o

Cola a tag script na página, a apontar para o teu servidor Pepe:

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
| `data-agent` | Puramente cosmético: dá nome à sessão local do visitante, para mais do que um widget conseguir partilhar a mesma página sem conflito. Um token de widget está sempre preso a um único agente, por isso isto nunca decide quem realmente responde. | `default` |
| `data-token` | O token de widget criado com `token add --widget`. | nenhum |
| `data-server` | O host a que ligar. | o próprio host do script |
| `data-title` | O texto do cabeçalho do painel. | "Chat" |
| `data-logo` | Uma imagem quadrada pequena, usada como ícone da bolha e junto ao título do cabeçalho; omite-a para manter o ícone de chat simples. | nenhum |
| `data-color` | A cor de destaque da bolha, do cabeçalho e dos botões. | `#ea580c` |
| `data-theme` | `light` ou `dark`: as cores base do painel, abaixo do cabeçalho. | `light` |
| `data-greeting` | A primeira mensagem mostrada antes de o visitante escrever seja o que for. | escolhida a partir de `data-lang`, ou inglês na falta dele |
| `data-position` | `left` ou `right`. | `right` |
| `data-lang` | O idioma **do próprio site** (por exemplo, `pt-PT`), não o do navegador do visitante: um site sabe em que língua foi escrito, um locale de navegador é apenas um palpite sobre quem o está a ler. Escolhe a saudação incorporada quando `data-greeting` não está definido, e é enviado uma única vez ao entrar na conversa, para o agente já se inclinar a responder nessa língua desde a sua primeira resposta. | nenhum |

Não há passo de build nem npm a instalar: o `widget.js` e a sua folha de estilo são servidos diretamente pelo teu servidor Pepe em `/plugin-assets/pepe-widget/`, a mesma rota genérica que qualquer asset estático de um futuro plugin usaria.

### Como funciona a sessão de um visitante

Cada visitante recebe um id aleatório, guardado no `localStorage` do navegador e enviado como sessão da ligação, de modo a que um recarregar de página continue a mesma conversa. Por baixo, o widget fala exatamente o mesmo protocolo descrito em [WebSocket](../websocket/): `prompt` a entrar, `delta`, `done`, `error`, `watch` e `session_ended` a sair. Um indicador de pontinhos a saltar aparece no painel enquanto o agente prepara a resposta, para o visitante nunca ficar na dúvida sobre se a mensagem chegou a sair.

O botão de nova conversa no cabeçalho, um simples "+", arranca de imediato uma conversa nova: fecha a ligação atual, limpa o painel, e religa com um id de sessão novo, que fica guardado logo ali, de modo que mesmo um recarregar completo da página continua a falar com a conversa nova, não com a antiga. Se for o próprio agente a terminar a conversa, através da sua ferramenta `end_session`, o painel mostra uma pequena nota de sistema nesse lugar, e a mensagem seguinte que enviares já começa do zero, sem precisares de clicar em nada.

<div class="note"><strong>Sem comandos de barra.</strong> O widget fala apenas o protocolo de streaming acima, e não uma sessão de chat completa: não existe <code>/model</code>, <code>/models</code>, nem qualquer outro comando de barra, só os controlos do próprio painel. Um widget fica sempre preso ao modelo do seu agente; para oferecer a um visitante um modelo diferente, cria antes um token de widget separado para um agente já configurado com esse modelo.</div>

Na página Chat do painel, as conversas do widget agrupam-se sob **Widget**, um subgrupo por site (o `allowed_origin` de cada token), de forma que ter mais do que um widget em sites diferentes mantém as conversas fáceis de separar, distintas do próprio chat interno do painel.

### Segurança

- **Preso à origem.** Um navegador que se liga com um dado token de widget é recusado a menos que o seu `Origin` corresponda exatamente ao `allowed_origin` desse token (ou ao host do teu próprio servidor). Uma cópia do script colada num site não registado é recusada antes de sequer alcançar o agente, e um token que vaze também não pode ser reutilizado a partir de outro site, nem mesmo de um para o qual esse mesmo servidor sirva outro widget.
- **Preso a um agente.** Um token de widget corre sempre o único agente para o qual foi criado; o widget não tem forma nenhuma de pedir um diferente.
- **Com limite de taxa.** Os prompts que passam por uma ligação de widget têm um teto (20 por minuto por predefinição, ajustável com `config :pepe, widget_rate_limit:` / `widget_rate_window_s:` caso te auto-alojes e precises de afinar isto), para que um token público, exposto no código-fonte da página, não possa ser martelado. Nenhuma outra superfície é afetada por este limite.
- **Não tratado como segredo.** O valor em bruto de um token de widget já vive em HTML público, legível com um simples "ver código-fonte" no site que o incorpora; por isso, ao contrário de um token de API normal, fica guardado de forma recuperável e continua visível no painel e no `manage_token list`. O que realmente o protege são os três pontos acima, não o facto de esconder a cadeia.

<div class="note"><strong>Dá-lhe um agente restrito.</strong> Um widget fica exposto à internet pública sem ninguém ali a aprovar chamadas de ferramenta. Vincula-o a um agente limitado a ferramentas seguras, só de leitura ou voltadas para o cliente, a mesma orientação de qualquer canal voltado para o cliente em <a href="./security/">Segurança e ambiente isolado</a>.</div>

### Fá-lo pela conversa

Um agente com a ferramenta `manage_token` consegue criar um token de widget diretamente numa conversa:

> Cria um token de widget para o agente support, permitido a partir de https://example.com.

O agente chama `manage_token` com `action: "create"`, `agent: "support"`, `widget: true`, e `allowed_origin: "https://example.com"`. Como criar um token não é uma operação só de leitura, a chamada passa pela barreira de permissão; o token em bruto vem de volta na resposta, para colares na tag script, e continua disponível a qualquer altura com `action: "list"`, já que um token de widget não é um segredo que valha a pena esconder.

A aparência funciona da mesma forma nas duas ações: passa qualquer combinação de `title`, `logo`, `color`, `theme`, `greeting` e `position` no `create`, ou mais tarde com `action: "update"` e o `id` do token:

> Muda a saudação do widget do support para "Olá! Precisas de ajuda?" e a cor para #2563eb.

O agente chama `manage_token` com `action: "update"`, `id: "<o id do token>"`, `greeting: "Olá! Precisas de ajuda?"` e `color: "#2563eb"`; qualquer campo deixado de fora da chamada mantém o valor que já tinha.
