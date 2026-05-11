---
title: Canais
description: Entende tipos de canal, associação a agentes, sessões, envio de ficheiros e encaminhamento.
---

Um canal liga um dos teus agentes a um sítio onde as pessoas já conversam.
Alguém envia uma mensagem, o Pepe executa o agente associado (invocando
ferramentas e lendo a resposta), e a resposta é entregue no mesmo canal. Não
escreves qualquer código de ligação. Adiciona uma ligação, aponta-a a um agente e
funciona.

Tudo nesta página pressupõe que já tens pelo menos um agente definido. Caso ainda
não tenhas, consulta primeiro o guia de agentes.

## Três formas de configurar

Tal como o resto do Pepe, os canais podem ser geridos de três formas, e esta
página mostra cada uma onde se aplica:

1. A linha de comandos `pepe`.
2. O painel web (a secção "Channels" lista os teus bots e ligações, e orienta-te
   ao adicionar um).
3. Por conversa. Um agente que dispõe da ferramenta de gestão adequada consegue
   criar e reassociar bots do Telegram, entregar ficheiros e encerrar uma
   conversa, tudo em linguagem corrente. Essas ações estão protegidas, por isso
   lê as notas "Fá-lo pela conversa" mais abaixo para saber o passo exato de
   confirmação.

Se vens de outro motor de agentes, o `pepe migrate` importa os canais que já lá
existem, em vez de teres de adicionar cada um à mão.

## Duas formas de canal

Os canais distinguem-se apenas na forma como uma mensagem chega ao Pepe:

- **Telegram** é um bot que o Pepe consulta. Nada precisa de estar acessível
  publicamente. Adiciona um token, associa-o a um agente, executa o gateway.
- **Canais por webhook** (WhatsApp, Slack, Discord, Microsoft Teams, Google Chat
  e uma rota de entrada genérica) recebem mensagens que a plataforma envia para
  um URL de retorno. O Pepe expõe um URL por ligação. Regista-o uma única vez
  junto do fornecedor.

Todos os canais por webhook, qualquer que seja a plataforma, são servidos pelo
mesmo endpoint de entrada:

```
/webhooks/:company/:provider/:slug
```

`:company` é o âmbito do inquilino, e é `root` quando não usas empresas.
`:provider` é o nome da plataforma, e `:slug` é o nome que deste à ligação.
Acrescentar um fornecedor nunca acrescenta um endpoint novo.

Estes são os canais por webhook que vêm com o Pepe, e o que cada um precisa:

| Canal | Como se liga | Configuração que precisa |
|---|---|---|
| **WhatsApp** | Webhook da Meta Cloud API | `phone_number_id`, `access_token`, `app_secret`, `verify_token` |
| **Slack** | Webhook da Events API | `bot_token` (`xoxb-`), `signing_secret` |
| **Discord** | Endpoint de Interactions (comandos de barra) | `public_key`, `application_id` |
| **Microsoft Teams** | Webhook do Bot Framework | `app_id`, `app_password`, `tenant_id` |
| **Google Chat** | Webhook da Chat API | `access_token` (OAuth para a Chat API) |

O Chatwoot também está disponível, como um [plugin](../plugins/) de canal em vez
de uma ligação nativa. Serve de frente ao WhatsApp, ao widget web e a outros, e
traz passagem nativa para um humano. Os plugins de canal são configurados no
separador **Integrations** do painel, e não em **Channels**.

## Notas de configuração por canal

- **Slack.** Cria uma aplicação, adiciona um scope de bot token, ativa as Event
  Subscriptions e aponta o request URL para o URL da ligação. O Pepe responde
  sozinho ao desafio `url_verification`. Adiciona os eventos `message.channels` e
  `app_mention`. O signing secret verifica cada pedido. Vê [Slack](../slack/).
- **Discord.** Isto usa o endpoint de Interactions, e não um bot de gateway, por
  isso responde a **comandos de barra**. Adiciona um comando com uma opção de
  texto e depois aponta o "Interactions Endpoint URL" da aplicação para o URL da
  ligação. A public key da aplicação verifica a assinatura Ed25519. O comando é
  confirmado de imediato e a resposta chega como follow-up. Vê
  [Discord](../discord/).
- **Microsoft Teams.** Regista um bot no Azure e aponta o respetivo messaging
  endpoint para o URL da ligação. O Pepe responde ao `serviceUrl` da activity com
  um token gerado a partir das credenciais da aplicação. Mantém o endpoint atrás
  de um proxy ou de um segredo: o JWT de entrada não é validado aqui. Vê
  [Microsoft Teams](../msteams/).
- **Google Chat.** Configura o endpoint de webhook (HTTP) da aplicação para o URL
  da ligação e fornece um `access_token` OAuth da Chat API. As respostas são
  publicadas de volta no espaço. Mantém o endpoint atrás de um proxy. Vê
  [Google Chat](../googlechat/).

## Associação, sessões e os dois modos

Cada ligação (e cada bot do Telegram) nomeia um `agent`. Essa é a associação.
Cada remetente distinto obtém a própria conversa, por isso o contexto é retido
por pessoa sem que tenhas de gerir nada.

Uma ligação por webhook tem ainda um `mode` que altera o comportamento do motor:

| | Suporte | Admin |
|--|---------|-------|
| Público | Virado para o cliente, aberto a qualquer um | O utilizador, restrito a remetentes autorizados |
| Histórico | Efémero, cada conversa isolada | Mantido entre mensagens |
| Memória | Nunca aprende | As conversas podem tornar-se memória |
| Comandos de barra | Tratados como texto simples | Ativados (por exemplo `/new` reinicia, `/model` muda de modelo) |

Suporte é o valor predefinido seguro para tudo o que o público consiga alcançar.
Combina-o com um agente restringido (apenas ferramentas seguras, já que não há uma
pessoa do teu lado para aprovar uma ação arriscada) e, se quiseres, um tempo limite
de sessão inativa. Admin é para um canal que só tu usas, onde os
comandos de barra e a memória são úteis.

Alguns campos afinam isto por ligação:

- `agent`: o agente a que esta ligação está associada.
- `mode`: `support` ou `admin`.
- `trainers`: quem pode transformar uma conversa em memória. `["*"]` é toda a
  gente, `[]` é ninguém, uma lista são apenas esses remetentes, ausente é o valor
  predefinido (todos).
- `session_ttl_min`: minutos de inatividade antes de a conversa ser descartada.
- `ephemeral`: quando verdadeiro, o histórico não é transportado entre mensagens.
- `commands`: se os comandos de barra são atendidos (ligados por predefinição no
  admin).

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

Podes editar este ficheiro à mão, mas a linha de comandos e o painel mantêm-no
válido por ti.

## Enviar ficheiros

Um agente pode entregar um ficheiro a quem está a conversar. Produz o ficheiro da
forma que preferir (por exemplo um passo `bash` que consulta uma base de dados e
escreve um `.xlsx`), e depois invoca a ferramenta `send_file` com o caminho:

```json
{
  "path": "/tmp/report.xlsx",
  "caption": "Aqui está o relatório desta semana."
}
```

O Pepe descobre em que canal está a conversa e entrega ali o ficheiro. O agente
nunca precisa de ids de conversa nem de tokens. O Telegram envia-o como documento.
O WhatsApp, o Slack e o Discord carregam-no como multimédia nas respetivas APIs.
Se o canal atual não puder receber anexos (o Microsoft Teams e o Google Chat
enviam apenas texto), a ferramenta comunica isso de volta ao agente em vez de
falhar em silêncio.

### Fá-lo pela conversa

A entrega de ficheiros é, ela própria, uma capacidade de conversa. Qualquer agente
com a ferramenta `send_file` fá-lo no momento em que pedes. Dirias:

> Vai buscar os registos da semana passada e envia-me a folha de cálculo.

O agente executa o passo que constrói o ficheiro, e depois invoca `send_file` com
o caminho resultante. Não há uma barreira de confirmação separada no `send_file`;
ele só entrega ao próprio canal da conversa atual, resolvido a partir da sessão,
por isso não consegue divulgar um ficheiro a mais ninguém.

## Encerrar uma conversa

Um agente de suporte pode fechar a própria conversa depois de uma troca terminar,
para que a mensagem seguinte dessa pessoa comece do zero. Um agente com a
ferramenta `end_session` fá-lo pela conversa:

> Obrigado, era tudo.

O agente envia primeiro a resposta final, e depois invoca `end_session`, que limpa
o contexto do fio ao vivo. O conhecimento aprendido fica intacto. Apenas a conversa
atual é reiniciada. Isto é útil num canal em modo `support` onde cada troca deve
ser independente.

## Encaminhamento entre agentes

Para além de associar um canal a um agente, um agente que dispõe da ferramenta
`set_route` pode alterar quais agentes podem escrever a quais, pela conversa. O
encaminhamento é dirigido, por isso permitir que o agente A escreva ao agente B
não permite que B escreva a A. Como edita a configuração, passa pela barreira de
permissão: confirma a alteração antes de ela ter efeito. Dirias:

> Deixa o agente de triagem passar para o agente de faturação.

O agente invoca `set_route` com `to: "billing"` (e `from` assume por predefinição
aquele com quem está a falar), ou `action: "deny"` para remover uma rota. Na linha
de comandos, o mesmo é `pepe agent route triage billing`.

## O que não vem incluído

O Signal, o IRC e o iMessage precisam de uma ligação persistente ou de uma ponte
específica da plataforma, que não encaixa no modelo de webhook, por isso estão
fora de âmbito por agora. Um canal novo pode sempre ser acrescentado como um
[plugin](../plugins/) de canal.

## Servir tudo

Um único comando serve a API HTTP compatível com OpenAI, o WebSocket, o painel, a
rota de webhook e cada bot do Telegram configurado:

```bash
pepe serve --port 4000
```

A porta também é lida da variável de ambiente `PORT`. Adiciona `--tunnel` para
abrir um túnel público e testar canais por webhook sem o teu próprio proxy
inverso. Define `PEPE_PUBLIC_URL` para que os URLs de retorno que registas com cada
fornecedor apontem para o teu host real.
