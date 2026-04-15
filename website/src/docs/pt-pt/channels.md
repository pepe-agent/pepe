---
title: Canais
description: Entende tipos de canal, associação a agentes, sessões, envio de ficheiros e encaminhamento.
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

- `agent`: o agente a que está ligação está associada.
- `mode`: `support` ou `admin`.
- `trainers`: quem pode transformar uma conversa em memória. `["*"]` é toda a
  gente, `[]` é ninguém, uma lista são apenas esses remetentes, ausente é o valor
  predefinido (todos).
- `session_ttl_min`: minutos de inactividade antes de a conversa ser descartada.
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

Pode editar este ficheiro à mão, mas a linha de comandos e o painel mantêm-no
válido por si.

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
O WhatsApp, o Slack e o Discord carregam-no como multimédia nas respectivas APIs.
Se o canal actual não puder receber anexos (o Microsoft Teams e o Google Chat
enviam apenas texto), a ferramenta comunica isso de volta ao agente em vez de
falhar em silêncio.

### Faça pela conversa

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
