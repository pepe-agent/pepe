---
title: Discord
description: Como responder a comandos de barra, ou a mensagens normais de canal, no teu servidor de Discord através de um agente do Pepe.
---

## Discord

O Discord dá ao Pepe duas formas diferentes de receber uma mensagem, e uma ligação pode
usar uma delas ou as duas:

- Um **comando de barra** (por exemplo `/ask`), entregue pelo endpoint de Interactions
  do Discord. Encaixa no gateway de webhook do Pepe tal como qualquer outro fornecedor:
  nenhum processo para manter a correr, é o Discord quem chama o teu servidor.
- Uma **mensagem normal** escrita num canal, numa DM, ou numa resposta, entregue pelo
  gateway do Discord: um WebSocket que o bot mantém aberto. Isto exige um opt-in e um
  token de bot (mais abaixo), por ser uma ligação persistente e não uma chamada de
  webhook.

Começa pelo assistente guiado (ou pelo painel):

```bash
pepe setup
```

O `config` de uma ligação guarda:

- `public_key`: a chave pública da aplicação (em hex), exigida para verificar a
  assinatura Ed25519.
- `application_id`: usado para publicar a resposta de seguimento.

Na aplicação do Discord, aponta "Interactions Endpoint URL" para o URL da ligação, e
acrescenta um comando de barra com uma opção de texto, por exemplo `/ask prompt:...`. O
Discord exige uma confirmação dentro de três segundos, por isso o Pepe responde primeiro
com uma resposta diferida, e só publica a resposta real como seguimento assim que o
agente terminar. O formato do URL de retorno é:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Os campos partilhados por qualquer ligação (`agent`, `mode`, `trainers`,
`session_ttl_min`, `ephemeral`, `commands`) e o funcionamento interno da rota genérica
estão descritos em [Webhooks](../webhooks/).

### Ficheiros num comando

Dá ao teu comando de barra uma **opção de anexo** e as pessoas podem enviar um ficheiro com ele: `/ask prompt:o que é que ele diz? file:<clip>`. Um clip de voz é transcrito antes de o agente correr, um documento chega com o texto já lido, e uma imagem chega como imagem a um modelo com visão. O anexo basta por si, pelo que `/ask file:<clip>` sem nada escrito também funciona.

É o único caminho que um ficheiro tem pelo endpoint de Interactions: vê comandos de barra e mais nada, por isso uma mensagem de voz ou um anexo publicado directamente no canal não chega ao Pepe por aí. Chega pelo outro caminho, pelo gateway: ver **Mensagens normais de canal** a seguir. O Pepe aceita ficheiros até 20 MB por omissão (`max_attachment_mb` na ligação aumenta ou diminui este limite), e vale o menor entre o limite do Pepe e o limite de envio do próprio Discord: 10 MB numa conta comum ou servidor sem boost, mais com Nitro ou um servidor com boost. Ver [Mensagens de voz](../voice/) e [Documentos](../documents/).

### Mensagens normais de canal

Uma ligação também pode responder a uma mensagem escrita directamente num canal, a uma
foto largada nele, a uma mensagem de voz gravada ali mesmo, ou a uma DM para o bot, não só
a um comando de barra. Isto exige um opt-in próprio, porque significa que o Pepe mantém
uma ligação persistente ao gateway do Discord, em vez de responder apenas a chamadas de
webhook:

```bash
pepe gateway discord add support --agent apoio --gateway --bot-token '${DISCORD_BOT_TOKEN}'
```

ou os campos equivalentes no painel (uma ligação pode ter `--application-id`/`--public-key`
para comandos de barra e `--gateway`/`--bot-token` para mensagens de canal ao mesmo tempo).
O `mix pepe serve` corre a ligação de ambas as formas. Flags:

- `--gateway`: liga este modo.
- `--bot-token '${ENV}'`: o token do bot, tirado do Discord Developer Portal, guardado
  como `${ENV_VAR}`. Ativa também a intent **Message Content** na página do Bot da
  aplicação, ou o Discord não entrega o texto de uma mensagem que não mencione o bot.
- `--no-require-mention`: num servidor, por omissão o bot só responde a uma mensagem que
  o @mencione ou responda a algo que ele disse. Passa esta flag para responder a
  qualquer mensagem num canal que ele consiga ver. Numa DM, o bot responde sempre,
  independentemente desta flag.
- `--max-attachment-mb N`: aumenta ou diminui o limite por omissão de 20 MB para essa
  ligação.

Anexos da própria mensagem, da mensagem a que ela responde (para se poder responder "o
que é que ele diz?" depois de a mensagem de voz já ter chegado), e de uma mensagem
reencaminhada para o bot contam todos, e passam pelo mesmo tratamento de
voz-para-transcrição, documento-para-texto, imagem-para-visão que um anexo de comando de
barra. As mensagens de uma ligação são respondidas pela ordem em que o Discord as
entregou. Se a ligação cair, volta a ligar-se e retoma sozinha, sem perder nada do que
foi dito no intervalo.

### Trocar de modelo

Os comandos `/model` e `/models` deixam qualquer pessoa ver ou mudar o modelo de IA que
lhe responde. No Discord chegam ao Pepe através do comando que já tens registado (o
`/ask` acima): tudo o que escreveres na opção `prompt:` é a mensagem que o Pepe recebe.
Só funcionam numa ligação em modo `admin` com `commands` ativado; em modo `support`
passam a ser tratados como texto normal. O `/models` lista os modelos disponíveis para o
projeto dessa ligação, e o `/model` mostra qual está ativo ou muda para outro:

```text
/model openrouter               # pergunta se a troca é só deste chat ou de todos
/model openrouter session       # troca só nesta conversa
/model openrouter global        # troca para todas as conversas desta ligação
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da sua própria conversa.
Trocá-lo **globalmente**, afetando todas as conversas dessa ligação, fica reservado aos
**formadores**, a mesma lista de confiança que já controla a memória. Define
`model_switch_locked: true` na ligação para desligar por completo essa troca de modelo a
quem não for formador.
