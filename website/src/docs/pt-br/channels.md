---
title: Canais
description: Entenda tipos de canal, vínculo com agentes, sessões, envio de arquivos e roteamento.
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

- `agent`: o agente ao qual está conexão está vinculada.
- `mode`: `support` ou `admin`.
- `trainers`: quem pode transformar uma conversa em memória. `["*"]` é todos,
  `[]` é ninguém, uma lista são apenas aqueles remetentes, ausente é o padrão
  (todos).
- `session_ttl_min`: minutos de inatividade antes de a conversa ser descartada.
- `ephemeral`: quando verdadeiro, o histórico não é levado entre mensagens.
- `commands`: se os comandos de barra são atendidos (ligados por padrão no
  admin).

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
  "caption": "Aqui está o relatório desta semana."
}
```

O Pepe descobre em qual canal a conversa está e entrega o arquivo ali. O agente
nunca precisa de ids de chat nem de tokens. O Telegram envia como documento. O
WhatsApp, o Slack e o Discord sobem como mídia nas APIs deles. Se o canal atual
não puder receber anexos (o Microsoft Teams e o Google Chat enviam só texto), a
ferramenta informa isso de volta ao agente em vez de falhar em silêncio.

### Faça pela conversa

A entrega de arquivos é, ela mesma, uma capacidade pela conversa. Qualquer agente com
a ferramenta `send_file` faz isso no momento em que você pede. Você diria:

> Puxe os cadastros da semana passada e me mande a planilha.

O agente roda o passo que monta o arquivo, e então chama `send_file` com o
caminho resultante. Não há uma trava de confirmação separada no `send_file`; ele
só entrega no próprio canal da conversa atual, resolvido a partir da sessão,
então ele não consegue vazar um arquivo para mais ninguém.

## Encerrar uma conversa

Um agente de suporte pode fechar a própria conversa depois que uma troca termina,
para que a próxima mensagem daquela pessoa comece do zero. Um agente com a
ferramenta `end_session` faz isso pela conversa:

> Obrigado, era só isso.

O agente envia primeiro a resposta final, e então chama `end_session`, que limpa
o contexto do fio ao vivo. O conhecimento aprendido dele fica intacto. Só a
conversa atual é reiniciada. Isso é útil em um canal em modo `support` onde cada
troca deveria ser independente.

## Roteamento entre agentes

Além de vincular um canal a um agente, um agente que tem a ferramenta
`set_route` pode mudar quais agentes podem mandar mensagem para quais, pela conversa.
O roteamento é direcionado, então permitir que o agente A escreva para o agente B
não permite que B escreva para A. Como ela edita a configuração, passa pela trava
de permissão: você confirma a mudança antes de ela valer. Você diria:

> Deixe o agente de triagem repassar para o agente de faturamento.

O agente chama `set_route` com `to: "billing"` (e `from` assume por padrão aquele
com quem você está falando), ou `action: "deny"` para remover uma rota. Na linha
de comando, a mesma coisa é `pepe agent route triage billing`.

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
