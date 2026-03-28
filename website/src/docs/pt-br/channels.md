---
title: Canais
description: Vincule um agente ao Telegram, WhatsApp, Slack, Discord, Microsoft Teams, Google Chat ou a um webhook de entrada genérico, e as pessoas simplesmente conversam com ele.
---

Um canal conecta um dos seus agentes a um lugar onde as pessoas já conversam.
Alguém envia uma mensagem, o Pepe executa o agente vinculado (chamando
ferramentas e lendo a resposta de volta), e a resposta é entregue no mesmo
canal. Você não escreve nenhum código de ligação. Você adiciona uma conexão,
aponta ela para um agente e pronto, funciona.

Tudo nesta página pressupõe que você já tem pelo menos um agente definido. Se
ainda não tem, veja primeiro o guia de agentes.

## Três maneiras de configurar

Como o resto do Pepe, os canais podem ser gerenciados de três maneiras, e esta
página mostra cada uma onde ela se aplica:

1. A linha de comando `pepe`.
2. O painel web (a seção "Channels" lista seus bots e conexões, e te guia na
   hora de adicionar um).
3. Por chat. Um agente que tem a ferramenta de gerenciamento certa pode criar e
   revincular bots do Telegram, entregar arquivos e encerrar uma conversa, tudo
   em linguagem comum. Essas ações são protegidas, então leia as notas "Faça por
   chat" mais abaixo para saber o passo exato de confirmação.

## Duas formas de canal

Os canais diferem apenas em como uma mensagem chega até o Pepe:

- **Telegram** é um bot que o Pepe consulta. Nada precisa ser acessível
  publicamente. Adicione um token, vincule a um agente, execute o gateway.
- **Canais por webhook** (WhatsApp, Slack, Discord, Microsoft Teams, Google Chat
  e uma rota de entrada genérica) recebem mensagens que a plataforma envia para
  uma URL de retorno. O Pepe expõe uma URL por conexão. Você a registra uma
  única vez com o provedor.

## Telegram

O Telegram é o canal mais rápido de colocar de pé porque não precisa de nenhuma
URL pública. Crie um bot com o @BotFather, copie o token dele e registre.

Configure o bot padrão de forma interativa:

```bash
pepe gateway telegram setup
```

Isso pede o token (você pode colar um token literal ou uma referência
`${ENV_VAR}`), um agente opcional para vincular e uma lista opcional de ids de
chat autorizados a falar com ele.

Você pode rodar mais de um bot, cada um vinculado a um agente diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou `${ENV_VAR}`.
- `--agent`: qual agente responde. Omita para usar seu agente padrão.
- `--trainers`: de quem esse bot pode aprender para a memória. Omita para todos,
  `none` para ninguém, ou uma lista separada por vírgulas de ids de usuário para
  apenas esses.
- `--heartbeat-minutes` e `--heartbeat-hours`: uma janela periódica opcional de
  despertar (para agentes que verificam coisas em um horário). As horas são uma
  janela local como `8-22`.
- `--progress`: como o bot sinaliza que está trabalhando enquanto uma execução
  está em andamento. Uma entre `reaction` (uma reação na sua mensagem),
  `ambient` (uma linha de atividade), `off` (só o indicador de digitação) ou
  `verbose` (um detalhamento por ferramenta).

Listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Rode o consultador em primeiro plano (um consultador por bot):

```bash
pepe gateway telegram
```

Normalmente você não precisa rodar isso separadamente. O `pepe serve` inicia os
bots do Telegram configurados junto com a API HTTP, então um único servidor em
execução cobre todos os canais de uma vez.

<div class="note"><strong>Painel.</strong> A seção Channels do painel lista seus
bots com um selo ao vivo de ativo/inativo, deixa você adicionar um bot, editar
com qual agente ele fala e removê-lo. Ela grava a mesma configuração que a linha
de comando.</div>

### Faça por chat

Um agente que tem a ferramenta `manage_channel` pode criar e revincular bots do
Telegram a partir de uma conversa. Como ela edita a configuração, cada chamada
passa pela trava de permissão: o agente propõe a mudança e você confirma antes
de ela ser aplicada.

Você diria:

> Adicione um bot do Telegram chamado sales que fale com o agente de vendas. O
> token está na variável de ambiente SALES_BOT_TOKEN.

O agente chama `manage_channel` com `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Duas proteções importam aqui:

- **Segredos nunca passam pelo chat.** Você informa o *nome* de uma variável de
  ambiente que guarda o token, nunca o token em si. Ele é armazenado como
  `${SALES_BOT_TOKEN}` e resolvido na hora da leitura, então o segredo cru nunca
  chega ao modelo nem aos registros. Um token cru (que contém dois pontos) é
  rejeitado.
- **O bot padrão protegido é intocável.** A ferramenta só mexe em bots com nome,
  nunca no `default`.

Outras ações do `manage_channel` são `list`, `set_agent` (revincular um bot a
outro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` e `remove`. Depois de qualquer mudança ela reconcilia os consultadores
em execução, então um bot inicia ou para ao vivo, sem reinício.

<div class="note"><strong>Só Telegram.</strong> A ferramenta de chat gerencia
bots do Telegram. As conexões por webhook (WhatsApp, Slack e as demais) são
criadas pela linha de comando, pelo painel ou pelo <code>pepe setup</code>, não
por chat.</div>

## Como funciona um canal por webhook

Todo canal por webhook, seja qual for a plataforma, é acessível em uma única
rota:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` é o escopo de inquilino. Use `root` para o escopo padrão
  (mostrado como "Principal" no painel), ou o identificador de uma empresa para
  isolar uma conexão naquele inquilino.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`,
  `msteams` ou `googlechat`.
- `<slug>` é o nome único que você deu à conexão.

Um `GET` para essa URL responde ao aperto de mão de verificação do provedor (o
Pepe devolve o desafio que a plataforma envia quando você registra a URL pela
primeira vez). Um `POST` é um evento de entrada. Em um `POST`, o Pepe resolve a
conexão, verifica a assinatura da requisição contra o segredo que você
configurou, extrai a mensagem, executa o agente vinculado e entrega a resposta
pela própria API do provedor. O trabalho do agente roda em segundo plano para
que a plataforma receba o retorno na hora (provedores como a Meta repetem um
webhook lento).

Há uma única rota genérica. Adicionar um novo provedor nunca adiciona um novo
ponto de acesso.

<div class="note"><strong>Host público.</strong> Canais por webhook precisam de
uma URL que a plataforma consiga alcançar. Exponha sua instância do Pepe atrás
de um proxy reverso ou de um túnel, e defina <code>PEPE_PUBLIC_URL</code> para
que as URLs de retorno que a linha de comando imprime fiquem completas. Para um
túnel rápido durante os testes, rode <code>pepe serve --tunnel</code>.</div>

## Vinculação, sessões e os dois modos

Cada conexão (e cada bot do Telegram) nomeia um `agent`. Essa é a vinculação.
Cada remetente distinto ganha a própria conversa, então o contexto é mantido por
pessoa sem que você gerencie nada.

Uma conexão por webhook também tem um `mode` que muda como o motor se comporta:

| | Suporte | Admin |
|--|---------|-------|
| Público | Voltado ao cliente, aberto a qualquer um | Você, restrito a remetentes autorizados |
| Histórico | Efêmero, cada chat isolado | Mantido entre mensagens |
| Memória | Nunca aprende | Conversas podem virar memória |
| Comandos de barra | Tratados como texto puro | Habilitados (por exemplo `/new` reinicia) |

Suporte é o padrão seguro para qualquer coisa que o público possa alcançar.
Combine com um agente restrito (só ferramentas seguras, já que não há uma pessoa
do seu lado para aprovar uma ação arriscada) e, se quiser, um tempo limite de
sessão ociosa. Admin é para um canal que só você usa, onde os comandos de barra
e a memória são úteis.

Alguns campos ajustam isso por conexão:

- `agent`: o agente ao qual esta conexão está vinculada.
- `mode`: `support` ou `admin`.
- `trainers`: quem pode transformar uma conversa em memória. `["*"]` é todos,
  `[]` é ninguém, uma lista são apenas aqueles remetentes, ausente é o padrão
  (todos).
- `session_ttl_min`: minutos de inatividade antes de a conversa ser descartada.
- `ephemeral`: quando verdadeiro, o histórico não é levado entre mensagens.
- `commands`: se os comandos de barra são atendidos (ligados por padrão no
  admin).

## WhatsApp

O WhatsApp usa a Cloud API da Meta. Ele tem uma linha de comando dedicada por ser
o canal por webhook mais comum. Adicione uma conexão:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

As credenciais da conexão (guardadas dentro do `config` dela):

- `phone_number_id`: o id do ponto de envio, vindo do app da Meta.
- `access_token`: o token bearer da Graph API. Guarde como `${ENV_VAR}`.
- `app_secret`: verifica o `X-Hub-Signature-256` de entrada. Guarde como
  `${ENV_VAR}`.
- `verify_token`: qualquer texto que você escolher. A Meta o devolve durante o
  aperto de mão de assinatura. Se você omitir a opção, o slug é usado.

Se você deixar de fora `--access-token` ou `--app-secret`, a linha de comando
grava uma referência de espaço reservado derivada do slug (por exemplo
`${WA_TOKEN_SUPPORT}`), para você preencher o valor real no seu ambiente depois.
O comando imprime a URL de retorno e o token de verificação. Cole os dois na
configuração de webhook do app da Meta:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Gerencie conexões:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

As outras opções do `whatsapp add` são `--company`, `--trainers`, `--ttl-min`,
`--ephemeral` e `--commands`, que correspondem aos campos por conexão descritos
acima. O painel adiciona e edita conexões do WhatsApp pela mesma seção Channels.

<div class="note"><strong>Regra das 24 horas.</strong> A Meta só permite
respostas em formato livre dentro de 24 horas da última mensagem do usuário. O
suporte reativo se encaixa nisso de forma natural. Mensagens proativas fora da
janela precisam de modelos pré-aprovados, que este canal não envia.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Esses provedores são configurados pela configuração guiada (ou pelo painel), que
pede exatamente os campos de que cada um precisa e imprime a URL de retorno para
registrar:

```bash
pepe setup
```

Escolha a opção de canal, escolha o provedor e o agente, e informe as
credenciais (uma referência `${ENV_VAR}` é aceita para qualquer segredo). Os
campos obrigatórios de cada provedor estão abaixo.

### Slack

O Slack usa a Events API. O `config` de uma conexão contém:

- `bot_token`: o token OAuth do usuário bot (`xoxb-...`), usado como bearer nas
  respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nas requisições de entrada.

No app do Slack, defina a URL de requisição de Event Subscriptions com a URL da
conexão e assine `message.channels` e `app_mention`. O primeiro salvamento
dispara um aperto de mão `url_verification`, que o Pepe responde na hora. As
respostas são publicadas com `chat.postMessage`. Formato da URL de retorno:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

### Discord

O Discord é ligado pelo ponto de acesso de Interactions (comandos de barra),
então ele se encaixa no gateway de webhook em vez de uma conexão persistente. O
`config` de uma conexão contém:

- `public_key`: a chave pública do app (hex), para a verificação de assinatura
  Ed25519 exigida.
- `application_id`: usado para publicar a resposta de acompanhamento.

No app do Discord, aponte "Interactions Endpoint URL" para a URL da conexão e
adicione um comando de barra com uma opção de texto (por exemplo
`/ask prompt:...`). O Discord exige um retorno em três segundos, então o Pepe
responde com uma resposta adiada e publica a resposta real como acompanhamento
assim que o agente termina.

### Microsoft Teams

O Teams usa o Bot Framework. O `config` de uma conexão contém:

- `app_id`: o id do app (cliente) Microsoft do bot.
- `app_password`: o segredo de cliente. Guarde como `${ENV_VAR}`.
- `tenant_id`: o id de inquilino do Azure (ou `botframework.com`).

As atividades de entrada chegam como `POST`s. As respostas voltam para a URL de
serviço da atividade com um token de acesso de app cunhado a partir das
credenciais de cliente. A menção ao bot é retirada do texto de entrada antes de
o agente ver.

### Google Chat

O Google Chat publica eventos de espaço na URL de retorno. O `config` de uma
conexão contém:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas
  respostas. Guarde como `${ENV_VAR}` e renove por fora.

Só eventos `MESSAGE` de uma pessoa são atendidos. As respostas são publicadas de
volta no espaço pela Chat REST API.

## Como uma conexão aparece na configuração

Não há banco de dados. As conexões vivem em `~/.pepe/config.json` sob
`webhooks`, indexadas por slug. Os segredos são escritos como `${ENV_VAR}` e
lidos em tempo de execução, nunca expandidos em disco. Uma conexão de suporte do
Slack aparece assim:

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

Você pode editar esse arquivo à mão, mas a linha de comando e o painel o mantêm
válido para você.

## Enviar arquivos

Um agente pode entregar um arquivo para quem está conversando. Ele produz o
arquivo do jeito que preferir (por exemplo um passo `bash` que consulta um banco
de dados e escreve um `.xlsx`), e então chama a ferramenta `send_file` com o
caminho:

```json
{
  "path": "/tmp/report.xlsx",
  "caption": "Here is this week's report."
}
```

O Pepe descobre em qual canal a conversa está e entrega o arquivo ali. O agente
nunca precisa de ids de chat nem de tokens. O Telegram envia como documento. O
WhatsApp, o Slack e o Discord sobem como mídia nas APIs deles. Se o canal atual
não puder receber anexos (o Microsoft Teams e o Google Chat enviam só texto), a
ferramenta informa isso de volta ao agente em vez de falhar em silêncio.

### Faça por chat

A entrega de arquivos é, ela mesma, uma capacidade por chat. Qualquer agente com
a ferramenta `send_file` faz isso no momento em que você pede. Você diria:

> Puxe os cadastros da semana passada e me mande a planilha.

O agente roda o passo que monta o arquivo, e então chama `send_file` com o
caminho resultante. Não há uma trava de confirmação separada no `send_file`; ele
só entrega no próprio canal da conversa atual, resolvido a partir da sessão,
então ele não consegue vazar um arquivo para mais ninguém.

## Encerrar uma conversa

Um agente de suporte pode fechar a própria conversa depois que uma troca termina,
para que a próxima mensagem daquela pessoa comece do zero. Um agente com a
ferramenta `end_session` faz isso por chat:

> Obrigado, era só isso.

O agente envia primeiro a resposta final, e então chama `end_session`, que limpa
o contexto do fio ao vivo. O conhecimento aprendido dele fica intacto. Só a
conversa atual é reiniciada. Isso é útil em um canal em modo `support` onde cada
troca deveria ser independente.

## Roteamento entre agentes

Além de vincular um canal a um agente, um agente que tem a ferramenta
`set_route` pode mudar quais agentes podem mandar mensagem para quais, pelo chat.
O roteamento é direcionado, então permitir que o agente A escreva para o agente B
não permite que B escreva para A. Como ela edita a configuração, passa pela trava
de permissão: você confirma a mudança antes de ela valer. Você diria:

> Deixe o agente de triagem repassar para o agente de faturamento.

O agente chama `set_route` com `to: "billing"` (e `from` assume por padrão aquele
com quem você está falando), ou `action: "deny"` para remover uma rota. Na linha
de comando, a mesma coisa é `pepe agent route triage billing`.

## Por baixo dos panos: o contrato do provedor

Cada canal por webhook é um pequeno módulo que implementa o mesmo contrato, então
todos se comportam de forma coerente e uma nova plataforma é um novo módulo em
vez de uma nova rota. As funções de retorno são:

- `name` e `label`: o segmento de URL do provedor e seu nome para pessoas.
- `config_schema`: os campos que o painel mostra para configurar uma conexão.
- `verify`: responder ao aperto de mão de verificação do `GET`.
- `authenticate`: verificar a assinatura em um `POST` de entrada contra o segredo
  da conexão e o corpo cru da requisição. Uma requisição que falha é descartada.
- `parse`: normalizar a carga da plataforma em zero ou mais mensagens simples.
  Atualizações de estado e recibos de entrega são ignorados.
- `respond` (opcional): produzir uma resposta síncrona quando o protocolo exige
  uma antes de qualquer trabalho do agente, como o desafio `url_verification` do
  Slack ou o ping e o retorno adiado do Discord.
- `deliver`: enviar uma resposta de texto de volta ao remetente.
- `deliver_file` (opcional): enviar um arquivo como anexo.

Se você escrever um plugin que implementa esse contrato, ele se registra como um
novo provedor sob o próprio `name`, acessível na mesma rota `/webhooks/...` sem
fiação extra.

## Servir tudo

Um único comando serve a API HTTP compatível com OpenAI, o WebSocket, o painel, a
rota de webhook e cada bot do Telegram configurado:

```bash
pepe serve --port 4000
```

A porta também é lida da variável de ambiente `PORT`. Adicione `--tunnel` para
abrir um túnel público e testar canais por webhook sem seu próprio proxy reverso.
Defina `PEPE_PUBLIC_URL` para que as URLs de retorno que você registra com cada
provedor apontem para seu host real.
