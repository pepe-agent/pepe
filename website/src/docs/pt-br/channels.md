---
title: Canais
description: Coloque seus agentes no Telegram, no WhatsApp, no Slack e em outros lugares assim. Como os canais funcionam, quem pode falar com eles, e como arquivos e repasses são entregues.
---

Um canal conecta um dos seus agentes a um lugar onde as pessoas já se falam.
Alguém manda uma mensagem, o Pepe roda o agente vinculado (chamando
ferramentas, lendo a resposta de volta), e a resposta é entregue naquele mesmo
canal. Você não escreve nenhum código de ligação: basta adicionar uma conexão,
apontá-la para um agente, e já funciona.

Tudo nesta página parte do princípio de que você já tem pelo menos um agente
definido. Se ainda não tem, veja primeiro o guia de agentes.

## Três jeitos de configurar

Como o resto do Pepe, os canais podem ser gerenciados de três formas, e esta
página mostra cada uma delas onde se aplica:

1. A linha de comando `pepe`.
2. O painel web, cuja seção "Channels" lista seus bots e conexões, e guia
   você na hora de adicionar um.
3. Pela conversa. Um agente com a ferramenta de gerenciamento certa consegue
   criar e revincular bots do Telegram, entregar arquivos e encerrar uma
   conversa, tudo em linguagem comum. Essas ações vêm protegidas, então
   confira as notas "Faça pela conversa" mais abaixo para saber o passo exato
   de confirmação.

Vindo de outro runtime de agentes? O `pepe migrate` importa os canais que já
existem lá, em vez de você ter que recriar cada um na mão.

## Duas formas de canal

Os canais diferem só em como a mensagem chega até o Pepe:

- **Telegram** é um bot do qual o próprio Pepe vai buscar as mensagens, então
  nada do seu lado precisa estar acessível pela internet. Basta adicionar um
  token, vincular a um agente e rodar o gateway.
- **Canais por webhook** (WhatsApp, Slack, Discord, Microsoft Teams, Google
  Chat e uma rota de entrada genérica) recebem mensagens que a própria
  plataforma entrega num endereço do seu servidor, então aí sim o Pepe precisa
  estar acessível pela internet. O Pepe expõe uma URL por conexão, e você a
  registra uma única vez junto ao provedor.

Todo canal por webhook, seja qual for a plataforma, é servido pelo mesmo
endpoint de entrada:

```
/webhooks/:project/:provider/:slug
```

`:project` é o projeto ao qual a conexão pertence, e vale `default` quando
você não criou nenhum projeto adicional. `:provider` é o nome da plataforma, e
`:slug` é o nome que você deu à conexão. Adicionar um provedor novo nunca cria
um endpoint novo.

Estes são os canais por webhook que já vêm com o Pepe, e o que cada um
precisa:

| Canal | Como se conecta | Configuração necessária |
|---|---|---|
| **WhatsApp** | Webhook da Meta Cloud API | `phone_number_id`, `access_token`, `app_secret`, `verify_token` |
| **Slack** | Webhook da Events API | `bot_token` (`xoxb-`), `signing_secret` |
| **Discord** | Endpoint de Interactions (comandos de barra) | `public_key`, `application_id` |
| **Microsoft Teams** | Webhook do Bot Framework | `app_id`, `app_password`, `tenant_id` |
| **Google Chat** | Webhook da Chat API | `access_token` (OAuth para a Chat API) |

O Chatwoot também está disponível, mas como um [plugin](../plugins/) de
canal, não como uma conexão nativa. Ele fica na frente do WhatsApp, do widget
web e de outros canais, e traz repasse nativo para um humano. Plugins de
canal se configuram na aba **Integrations** do painel, não na **Channels**.

## Notas de configuração por canal

- **Slack.** Crie um app, adicione um escopo de bot token, ative os Event
  Subscriptions e aponte a request URL para a URL da sua conexão. O próprio
  Pepe responde ao desafio `url_verification`. Adicione os eventos
  `message.channels` e `app_mention`. O signing secret é quem verifica cada
  requisição. Veja [Slack](../slack/).
- **Discord.** Aqui o canal usa o endpoint de Interactions, não um bot de
  gateway, então ele responde a **comandos de barra**. Adicione um comando com
  uma opção de texto e depois aponte a "Interactions Endpoint URL" do app para
  a URL da conexão. A public key do app é quem verifica a assinatura Ed25519.
  O comando é confirmado na hora, e a resposta chega em seguida como
  follow-up. Veja [Discord](../discord/).
- **Microsoft Teams.** Registre um bot no Azure e aponte o messaging endpoint
  dele para a URL da conexão. O Pepe responde ao `serviceUrl` da activity com
  um token gerado a partir das credenciais do app. O JWT do Bot Framework que
  chega é validado, então o endpoint aceita POSTs vindos direto da Microsoft.
  Veja [Microsoft Teams](../msteams/).
- **Google Chat.** Configure o endpoint de webhook (HTTP) do app para a URL da
  conexão, e forneça um `access_token` OAuth da Chat API. As respostas voltam
  publicadas no próprio espaço. Mantenha o endpoint atrás de um proxy. Veja
  [Google Chat](../googlechat/).

## Vinculação, sessões e os dois modos

Cada conexão (e cada bot do Telegram) nomeia um `agent`, e essa é a
vinculação. Cada remetente distinto ganha a própria conversa, então o contexto
é mantido por pessoa sem que você precise gerenciar nada.

Uma conexão por webhook também tem um `mode`, que muda como o runtime se
comporta:

| | Suporte | Admin |
|--|---------|-------|
| Público | Voltado ao cliente, aberto a qualquer um | Você, restrito a remetentes autorizados |
| Histórico | Efêmero, cada chat isolado | Mantido entre mensagens |
| Memória | Nunca aprende | Conversas podem virar memória |
| Comandos de barra | Tratados como texto puro | Habilitados (por exemplo `/new` reinicia, `/model` troca de modelo) |

Suporte é o padrão seguro para qualquer coisa que o público em geral consiga
alcançar. Combine com um agente restrito (só com ferramentas seguras, já que
não há ninguém do seu lado para aprovar uma ação arriscada) e, se quiser, um
tempo limite de sessão ociosa. Admin é para um canal que só você usa, onde os
comandos de barra e a memória fazem sentido.

Alguns campos ajustam isso por conexão:

- `agent`: o agente ao qual esta conexão está vinculada.
- `mode`: `support` ou `admin`.
- `trainers`: quem pode transformar uma conversa em memória. `["*"]` é todo
  mundo, `[]` é ninguém, uma lista restringe a esses remetentes, e ausente
  significa o padrão (todos).
- `session_ttl_min`: minutos de inatividade antes de a conversa ser
  descartada.
- `ephemeral`: quando verdadeiro, o histórico não é levado entre mensagens.
- `commands`: se os comandos de barra são atendidos (ligado por padrão no
  modo admin).

## Como uma conexão aparece na configuração

Não existe banco de dados aqui. As conexões vivem em `~/.pepe/config.json`,
dentro de `webhooks`, indexadas por slug. Os segredos são escritos como
`${ENV_VAR}` e lidos em tempo de execução, nunca expandidos em disco. Uma
conexão de suporte do Slack tem esta cara:

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

Dá para editar esse arquivo à mão, mas tanto a linha de comando quanto o
painel já cuidam de mantê-lo válido para você.

## Enviar arquivos

Um agente pode entregar um arquivo direto para quem está do outro lado da
conversa. Ele produz esse arquivo do jeito que preferir (por exemplo, um passo
de `bash` que consulta um banco de dados e escreve um `.xlsx`), e então chama
a ferramenta `send_file` com o caminho:

```json
{
  "path": "/tmp/report.xlsx",
  "caption": "Aqui está o relatório desta semana."
}
```

O Pepe descobre sozinho em qual canal a conversa está e entrega o arquivo ali
mesmo. O agente nunca precisa saber ids de chat nem tokens. O Telegram manda
como documento; o WhatsApp, o Slack e o Discord sobem como mídia pelas
próprias APIs deles. Se o canal atual não conseguir receber anexos (o
Microsoft Teams e o Google Chat só mandam texto), a ferramenta avisa isso de
volta ao agente, em vez de falhar em silêncio.

### Faça pela conversa

Entregar arquivo é, ele mesmo, uma capacidade que já funciona pela conversa.
Qualquer agente com a ferramenta `send_file` faz isso assim que você pede.
Você diria algo como:

> Puxe os cadastros da semana passada e me mande a planilha.

O agente roda o passo que monta o arquivo e então chama `send_file` com o
caminho resultante. Não existe uma barreira de confirmação separada no
`send_file`: ele só entrega no canal da própria conversa atual, resolvido a
partir da sessão, então não tem como vazar um arquivo para mais ninguém.

## Encerrar uma conversa

Um agente de suporte pode fechar a própria conversa assim que uma troca
termina, para que a próxima mensagem daquela pessoa comece do zero. Um agente
com a ferramenta `end_session` faz isso pela conversa:

> Obrigado, era só isso.

O agente manda a resposta final primeiro, e só depois chama `end_session`, que
limpa o contexto da conversa em andamento. O que ele já aprendeu fica
intacto: só a conversa atual é reiniciada. Isso é útil num canal em modo
`support`, onde cada troca deveria ser independente da anterior.

## Roteamento entre agentes

Além de vincular um canal a um agente, um agente com a ferramenta
`set_route` pode mudar, pela conversa, quais agentes podem mandar mensagem
para quais. O roteamento é direcionado, então permitir que o agente A escreva
para o agente B não permite o contrário. Como isso edita a configuração,
passa pela barreira de permissão: você confirma a mudança antes de ela valer.
Você diria:

> Deixe o agente de triagem repassar para o agente de faturamento.

O agente chama `set_route` com `to: "billing"` (e `from` assume por padrão
aquele com quem você está falando), ou `action: "deny"` para remover uma rota.
Na linha de comando, a mesma coisa é `pepe agent route triage billing`.

## O que não vem embutido

Signal, IRC e iMessage exigem uma conexão persistente ou uma ponte específica
da plataforma, algo que não cabe no modelo de webhook, então ficam fora de
escopo por enquanto. Um canal novo sempre pode ser adicionado como um
[plugin](../plugins/) de canal.

## Servir tudo de uma vez

Um único comando serve a API HTTP compatível com OpenAI, o WebSocket, o
painel, a rota de webhook e cada bot do Telegram configurado:

```bash
pepe serve --port 4000
```

A porta também é lida da variável de ambiente `PORT`. Adicione `--tunnel` para
abrir um túnel público e testar canais por webhook sem precisar do seu
próprio proxy reverso. Defina `PEPE_PUBLIC_URL` para que as URLs de retorno
que você registra em cada provedor apontem para o seu host de verdade.
