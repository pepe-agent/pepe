---
title: Canais
description: Associe um agente ao Telegram, WhatsApp, Slack, Discord, Microsoft Teams, Google Chat ou a um webhook de entrada genérico, e as pessoas simplesmente conversam com ele.
---

Um canal liga um dos seus agentes a um sítio onde as pessoas já conversam.
Alguém envia uma mensagem, o Pepe executa o agente associado (invocando
ferramentas e lendo a resposta), e a resposta é entregue no mesmo canal. Não
escreve qualquer código de ligação. Adiciona uma ligação, aponta-a a um agente e
funciona.

Tudo nesta página pressupõe que já tem pelo menos um agente definido. Caso ainda
não tenha, consulte primeiro o guia de agentes.

## Três formas de configurar

Tal como o resto do Pepe, os canais podem ser geridos de três formas, e esta
página mostra cada uma onde se aplica:

1. A linha de comandos `pepe`.
2. O painel web (a secção "Channels" lista os seus bots e ligações, e orienta-o
   ao adicionar um).
3. Por conversa. Um agente que dispõe da ferramenta de gestão adequada consegue
   criar e reassociar bots do Telegram, entregar ficheiros e encerrar uma
   conversa, tudo em linguagem corrente. Essas acções estão protegidas, por isso
   leia as notas "Faça pela conversa" mais abaixo para saber o passo exacto de
   confirmação.

## Duas formas de canal

Os canais distinguem-se apenas na forma como uma mensagem chega ao Pepe:

- **Telegram** é um bot que o Pepe consulta. Nada precisa de estar acessível
  publicamente. Adicione um token, associe-o a um agente, execute a comporta.
- **Canais por webhook** (WhatsApp, Slack, Discord, Microsoft Teams, Google Chat
  e uma rota de entrada genérica) recebem mensagens que a plataforma envia para
  um URL de retorno. O Pepe expõe um URL por ligação. Regista-o uma única vez
  junto do fornecedor.

## Telegram

O Telegram é o canal mais rápido de pôr de pé porque não precisa de qualquer URL
público. Crie um bot com o @BotFather, copie o respectivo token e registe-o.

Configure o bot predefinido de forma interactiva:

```bash
pepe gateway telegram setup
```

Isto pede o token (pode colar um token literal ou uma referência `${ENV_VAR}`),
um agente opcional para associar e uma lista opcional de ids de conversa
autorizados a falar com ele.

Pode executar mais do que um bot, cada um associado a um agente diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou `${ENV_VAR}`.
- `--agent`: qual o agente que responde. Omita para usar o seu agente
  predefinido.
- `--trainers`: de quem este bot pode aprender para a memória. Omita para todos,
  `none` para ninguém, ou uma lista separada por vírgulas de ids de utilizador
  para apenas esses.
- `--heartbeat-minutes` e `--heartbeat-hours`: uma janela periódica opcional de
  activação (para agentes que verificam coisas segundo um horário). As horas são
  uma janela local como `8-22`.
- `--progress`: como o bot sinaliza que está a trabalhar enquanto uma execução
  decorre. Uma entre `reaction` (uma reacção na sua mensagem), `ambient` (uma
  linha de actividade), `off` (apenas o indicador de escrita) ou `verbose` (um
  detalhe por ferramenta).

Listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Execute o consultador em primeiro plano (um consultador por bot):

```bash
pepe gateway telegram
```

Normalmente não precisa de executar isto em separado. O `pepe serve` arranca com
os bots do Telegram configurados a par da API HTTP, por isso um único servidor em
execução cobre todos os canais de uma vez.

<div class="note"><strong>Painel.</strong> A secção Channels do painel lista os
seus bots com um distintivo ao vivo de activo/inactivo, permite-lhe adicionar um
bot, editar com que agente ele fala e removê-lo. Grava a mesma configuração que a
linha de comandos.</div>

### Fá-lo por chat

Um agente que tenha a ferramenta `manage_channel` consegue criar e reassociar
bots do Telegram a partir de uma conversa. Como edita a configuração, cada
chamada passa pela cancela de permissão: o agente propõe a alteração e o
utilizador confirma antes de ela ser aplicada.

Diria:

> Adiciona um bot do Telegram chamado sales que fale com o agente de vendas. O
> token está na variável de ambiente SALES_BOT_TOKEN.

O agente invoca `manage_channel` com `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Aqui importam duas
salvaguardas:

- **Os segredos nunca passam pela conversa.** Fornece o *nome* de uma variável de
  ambiente que guarda o token, nunca o token em si. É armazenado como
  `${SALES_BOT_TOKEN}` e resolvido no momento da leitura, por isso o segredo em
  bruto nunca chega ao modelo nem aos registos. Um token em bruto (que contém
  dois pontos) é rejeitado.
- **O bot predefinido protegido é intocável.** A ferramenta só mexe em bots com
  nome, nunca no `default`.

Outras acções do `manage_channel` são `list`, `set_agent` (reassociar um bot a
outro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` e `remove`. Após qualquer alteração, reconcilia os consultadores em
execução, por isso um bot arranca ou pára ao vivo, sem reinício.

<div class="note"><strong>Apenas Telegram.</strong> A ferramenta de conversa
gere bots do Telegram. As ligações por webhook (WhatsApp, Slack e as restantes)
são criadas pela linha de comandos, pelo painel ou pelo <code>pepe setup</code>,
não pela conversa.</div>

## Como funciona um canal por webhook

Todo o canal por webhook, seja qual for a plataforma, está acessível numa única
rota:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` é o âmbito de inquilino. Use `root` para o âmbito predefinido
  (apresentado como "Principal" no painel), ou o identificador de uma empresa
  para isolar uma ligação nesse inquilino.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`, `msteams`
  ou `googlechat`.
- `<slug>` é o nome único que deu à ligação.

Um `GET` a esse URL responde ao aperto de mão de verificação do fornecedor (o
Pepe devolve o desafio que a plataforma envia quando regista o URL pela primeira
vez). Um `POST` é um evento de entrada. Num `POST`, o Pepe resolve a ligação,
verifica a assinatura do pedido contra o segredo que configurou, extrai a
mensagem, executa o agente associado e entrega a resposta pela própria API do
fornecedor. O trabalho do agente decorre em segundo plano para que a plataforma
receba a confirmação de imediato (fornecedores como a Meta repetem um webhook
lento).

Há uma única rota genérica. Adicionar um novo fornecedor nunca acrescenta um novo
ponto de acesso.

<div class="note"><strong>Host público.</strong> Os canais por webhook precisam
de um URL que a plataforma consiga alcançar. Exponha a sua instância do Pepe atrás
de um proxy inverso ou de um túnel, e defina <code>PEPE_PUBLIC_URL</code> para que
os URLs de retorno que a linha de comandos imprime fiquem completos. Para um túnel
rápido durante os testes, execute <code>pepe serve --tunnel</code>.</div>

## Associação, sessões e os dois modos

Cada ligação (e cada bot do Telegram) nomeia um `agent`. Essa é a associação.
Cada remetente distinto obtém a própria conversa, por isso o contexto é retido
por pessoa sem que tenha de gerir nada.

Uma ligação por webhook tem ainda um `mode` que altera o comportamento do motor:

| | Suporte | Admin |
|--|---------|-------|
| Público | Virado para o cliente, aberto a qualquer um | O utilizador, restrito a remetentes autorizados |
| Histórico | Efémero, cada conversa isolada | Mantido entre mensagens |
| Memória | Nunca aprende | As conversas podem tornar-se memória |
| Comandos de barra | Tratados como texto simples | Activados (por exemplo `/new` reinicia) |

Suporte é o valor predefinido seguro para tudo o que o público consiga alcançar.
Combine-o com um agente restringido (apenas ferramentas seguras, já que não há uma
pessoa do seu lado para aprovar uma acção arriscada) e, se quiser, um tempo limite
de sessão inactiva. Admin é para um canal que só o utilizador usa, onde os
comandos de barra e a memória são úteis.

Alguns campos afinam isto por ligação:

- `agent`: o agente a que esta ligação está associada.
- `mode`: `support` ou `admin`.
- `trainers`: quem pode transformar uma conversa em memória. `["*"]` é toda a
  gente, `[]` é ninguém, uma lista são apenas esses remetentes, ausente é o valor
  predefinido (todos).
- `session_ttl_min`: minutos de inactividade antes de a conversa ser descartada.
- `ephemeral`: quando verdadeiro, o histórico não é transportado entre mensagens.
- `commands`: se os comandos de barra são atendidos (ligados por predefinição no
  admin).

## WhatsApp

O WhatsApp usa a Cloud API da Meta. Tem uma linha de comandos dedicada por ser o
canal por webhook mais comum. Adicione uma ligação:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

As credenciais da ligação (guardadas dentro do respectivo `config`):

- `phone_number_id`: o id do ponto de envio, proveniente da aplicação da Meta.
- `access_token`: o token bearer da Graph API. Guarde-o como `${ENV_VAR}`.
- `app_secret`: verifica o `X-Hub-Signature-256` de entrada. Guarde-o como
  `${ENV_VAR}`.
- `verify_token`: qualquer texto que escolher. A Meta devolve-o durante o aperto
  de mão de subscrição. Se omitir a opção, é usado o slug.

Se deixar de fora `--access-token` ou `--app-secret`, a linha de comandos grava
uma referência de marcador derivada do slug (por exemplo `${WA_TOKEN_SUPPORT}`),
para que preencha o valor real no seu ambiente mais tarde. O comando imprime o URL
de retorno e o token de verificação. Cole ambos na configuração de webhook da
aplicação da Meta:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Gerir ligações:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

As outras opções do `whatsapp add` são `--company`, `--trainers`, `--ttl-min`,
`--ephemeral` e `--commands`, que correspondem aos campos por ligação descritos
acima. O painel adiciona e edita ligações do WhatsApp pela mesma secção Channels.

<div class="note"><strong>Regra das 24 horas.</strong> A Meta só permite respostas
em formato livre dentro de 24 horas da última mensagem do utilizador. O suporte
reactivo encaixa-se nisto de forma natural. As mensagens proactivas fora da janela
precisam de modelos pré-aprovados, que este canal não envia.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estes fornecedores são configurados pela configuração guiada (ou pelo painel), que
pede exactamente os campos de que cada um precisa e imprime o URL de retorno a
registar:

```bash
pepe setup
```

Escolha a opção de canal, escolha o fornecedor e o agente, e introduza as
credenciais (uma referência `${ENV_VAR}` é aceite para qualquer segredo). Os
campos obrigatórios de cada fornecedor estão abaixo.

### Slack

O Slack usa a Events API. O `config` de uma ligação contém:

- `bot_token`: o token OAuth do utilizador bot (`xoxb-...`), usado como bearer nas
  respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nos pedidos de entrada.

Na aplicação do Slack, defina o URL de pedido de Event Subscriptions com o URL da
ligação e subscreva `message.channels` e `app_mention`. A primeira gravação
dispara um aperto de mão `url_verification`, que o Pepe responde de imediato. As
respostas são publicadas com `chat.postMessage`. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

### Discord

O Discord é ligado pelo ponto de acesso de Interactions (comandos de barra), por
isso encaixa-se na comporta de webhook em vez de uma ligação persistente. O
`config` de uma ligação contém:

- `public_key`: a chave pública da aplicação (hex), para a verificação de
  assinatura Ed25519 exigida.
- `application_id`: usado para publicar a resposta de seguimento.

Na aplicação do Discord, aponte "Interactions Endpoint URL" para o URL da ligação
e adicione um comando de barra com uma opção de texto (por exemplo
`/ask prompt:...`). O Discord exige uma confirmação em três segundos, por isso o
Pepe responde com uma resposta diferida e publica a resposta real como seguimento
assim que o agente termina.

### Microsoft Teams

O Teams usa o Bot Framework. O `config` de uma ligação contém:

- `app_id`: o id da aplicação (cliente) Microsoft do bot.
- `app_password`: o segredo de cliente. Guarde-o como `${ENV_VAR}`.
- `tenant_id`: o id de inquilino do Azure (ou `botframework.com`).

As actividades de entrada chegam como `POST`s. As respostas voltam para o URL de
serviço da actividade com um token de acesso de aplicação cunhado a partir das
credenciais de cliente. A menção ao bot é retirada do texto de entrada antes de o
agente o ver.

### Google Chat

O Google Chat publica eventos de espaço no URL de retorno. O `config` de uma
ligação contém:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas respostas.
  Guarde-o como `${ENV_VAR}` e renove-o por fora.

Apenas os eventos `MESSAGE` de uma pessoa são atendidos. As respostas são
publicadas de volta no espaço pela Chat REST API.

## Como uma ligação aparece na configuração

Não há base de dados. As ligações vivem em `~/.pepe/config.json` sob `webhooks`,
indexadas por slug. Os segredos são escritos como `${ENV_VAR}` e lidos em tempo de
execução, nunca expandidos em disco. Uma ligação de suporte do Slack aparece
assim:

```json
{
  "webhooks": {
    "support": {
      "provider": "slack",
      "agent": "helpdesk",
      "mode": "support",
      "config": {
        "bot_token": "${SLACK_BOT_TOKEN}",
        "signing_secret": "${SLACK_SIGNING_SECRET}"
      }
    }
  }
}
```

Pode editar este ficheiro à mão, mas a linha de comandos e o painel mantêm-no
válido por si.

## Enviar ficheiros

Um agente pode entregar um ficheiro a quem está a conversar. Produz o ficheiro da
forma que preferir (por exemplo um passo `bash` que consulta uma base de dados e
escreve um `.xlsx`), e depois invoca a ferramenta `send_file` com o caminho:

```json
{
  "path": "/tmp/report.xlsx",
  "caption": "Here is this week's report."
}
```

O Pepe descobre em que canal está a conversa e entrega ali o ficheiro. O agente
nunca precisa de ids de conversa nem de tokens. O Telegram envia-o como documento.
O WhatsApp, o Slack e o Discord carregam-no como multimédia nas respectivas APIs.
Se o canal actual não puder receber anexos (o Microsoft Teams e o Google Chat
enviam apenas texto), a ferramenta comunica isso de volta ao agente em vez de
falhar em silêncio.

### Fá-lo por chat

A entrega de ficheiros é, ela própria, uma capacidade de conversa. Qualquer agente
com a ferramenta `send_file` fá-lo no momento em que pede. Diria:

> Vai buscar os registos da semana passada e envia-me a folha de cálculo.

O agente executa o passo que constrói o ficheiro, e depois invoca `send_file` com
o caminho resultante. Não há uma cancela de confirmação separada no `send_file`;
ele só entrega ao próprio canal da conversa actual, resolvido a partir da sessão,
por isso não consegue divulgar um ficheiro a mais ninguém.

## Encerrar uma conversa

Um agente de suporte pode fechar a própria conversa depois de uma troca terminar,
para que a mensagem seguinte dessa pessoa comece do zero. Um agente com a
ferramenta `end_session` fá-lo pela conversa:

> Obrigado, era tudo.

O agente envia primeiro a resposta final, e depois invoca `end_session`, que limpa
o contexto do fio ao vivo. O conhecimento aprendido fica intacto. Apenas a conversa
actual é reiniciada. Isto é útil num canal em modo `support` onde cada troca deve
ser independente.

## Encaminhamento entre agentes

Para além de associar um canal a um agente, um agente que dispõe da ferramenta
`set_route` pode alterar quais agentes podem escrever a quais, pela conversa. O
encaminhamento é direccionado, por isso permitir que o agente A escreva ao agente B
não permite que B escreva a A. Como edita a configuração, passa pela cancela de
permissão: confirma a alteração antes de ela ter efeito. Diria:

> Deixa o agente de triagem passar para o agente de facturação.

O agente invoca `set_route` com `to: "billing"` (e `from` assume por predefinição
aquele com quem está a falar), ou `action: "deny"` para remover uma rota. Na linha
de comandos, o mesmo é `pepe agent route triage billing`.

## Por dentro: o contrato do fornecedor

Cada canal por webhook é um pequeno módulo que implementa o mesmo contrato, por
isso todos se comportam de forma coerente e uma nova plataforma é um novo módulo em
vez de uma nova rota. As funções de retorno são:

- `name` e `label`: o segmento de URL do fornecedor e o respectivo nome para
  pessoas.
- `config_schema`: os campos que o painel apresenta para configurar uma ligação.
- `verify`: responder ao aperto de mão de verificação do `GET`.
- `authenticate`: verificar a assinatura num `POST` de entrada contra o segredo da
  ligação e o corpo em bruto do pedido. Um pedido que falha é descartado.
- `parse`: normalizar a carga da plataforma em zero ou mais mensagens simples. As
  actualizações de estado e os recibos de entrega são ignorados.
- `respond` (opcional): produzir uma resposta síncrona quando o protocolo exige
  uma antes de qualquer trabalho do agente, como o desafio `url_verification` do
  Slack ou o ping e a confirmação diferida do Discord.
- `deliver`: enviar uma resposta de texto de volta ao remetente.
- `deliver_file` (opcional): enviar um ficheiro como anexo.

Se escrever uma extensão que implementa este contrato, ela regista-se como um novo
fornecedor sob o próprio `name`, acessível na mesma rota `/webhooks/...` sem
ligações extra.

## Servir tudo

Um único comando serve a API HTTP compatível com OpenAI, o WebSocket, o painel, a
rota de webhook e cada bot do Telegram configurado:

```bash
pepe serve --port 4000
```

A porta também é lida da variável de ambiente `PORT`. Adicione `--tunnel` para
abrir um túnel público e testar canais por webhook sem o seu próprio proxy
inverso. Defina `PEPE_PUBLIC_URL` para que os URLs de retorno que regista com cada
fornecedor apontem para o seu host real.
