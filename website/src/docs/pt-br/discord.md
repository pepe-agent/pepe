---
title: Discord
description: Responda comandos de barra, ou mensagens comuns de canal, no seu servidor do Discord com um agente do Pepe.
---

## Discord

O Discord dá ao Pepe duas formas diferentes de receber uma mensagem, e uma conexão pode
usar uma delas ou as duas:

- Um **comando de barra** (`/ask`, por exemplo), entregue pelo endpoint de Interactions do
  Discord. Isso se encaixa no gateway de webhook do Pepe do mesmo jeito que qualquer outro
  provedor: nenhum processo para manter rodando, é o Discord quem chama o seu servidor.
- Uma **mensagem comum** digitada num canal, numa DM, ou numa resposta, entregue pelo
  gateway do Discord: um WebSocket que o bot mantém aberto. Isso exige um opt-in e um token
  de bot (mais abaixo), por ser uma conexão persistente e não uma chamada de webhook.

Comece pelo assistente guiado (ou direto pelo dashboard):

```bash
pepe setup
```

O `config` de uma conexão guarda:

- `public_key`: a chave pública do app (em hex), usada na verificação obrigatória de
  assinatura Ed25519.
- `application_id`: usado para publicar a resposta de acompanhamento.

No aplicativo do Discord, aponte "Interactions Endpoint URL" para a URL dessa conexão, e
crie um comando de barra com uma opção de texto (por exemplo, `/ask prompt:...`). Como o
Discord exige uma confirmação em até três segundos, o Pepe primeiro responde com uma
resposta adiada, e só publica a resposta de verdade como acompanhamento assim que o agente
termina de processar. O formato da URL de retorno é:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Veja [Webhooks](../webhooks/) para conhecer os campos que toda conexão compartilha
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e entender como a
rota genérica funciona por trás disso.

### Arquivos em um comando

Dê ao seu comando de barra uma **opção de anexo** e as pessoas podem mandar um arquivo junto: `/ask prompt:o que ele fala? file:<áudio>`. Um áudio é transcrito antes de o agente rodar, um documento chega com o texto já lido, e uma imagem chega como imagem a um modelo com visão. O anexo sozinho já basta, então `/ask file:<áudio>` sem nada digitado também funciona.

Esse é o único caminho que um arquivo tem pelo endpoint de Interactions: ele enxerga comandos de barra e mais nada, então um áudio ou um anexo postado direto no canal não chega ao Pepe por aí. Chega pelo outro caminho, pelo gateway: veja **Mensagens comuns de canal** logo abaixo. O Pepe aceita arquivos de até 20 MB por padrão (`max_attachment_mb` na conexão aumenta ou diminui esse limite), e vale o menor entre o limite do Pepe e o limite de upload do próprio Discord: 10 MB numa conta comum ou servidor sem boost, mais com Nitro ou um servidor com boost. Veja [Mensagens de voz](../voice/) e [Documentos](../documents/).

### Mensagens comuns de canal

Uma conexão também pode responder a uma mensagem digitada direto num canal, uma foto solta
nele, um áudio gravado ali mesmo, ou uma DM para o bot, não só um comando de barra. Isso
exige um opt-in próprio, porque significa que o Pepe mantém uma conexão persistente com o
gateway do Discord, em vez de só responder chamadas de webhook:

```bash
pepe gateway discord add support --agent atendimento --gateway --bot-token '${DISCORD_BOT_TOKEN}'
```

ou os campos equivalentes no dashboard (uma conexão pode ter `--application-id`/`--public-key`
para comandos de barra e `--gateway`/`--bot-token` para mensagens de canal ao mesmo tempo).
O `mix pepe serve` roda a conexão dos dois jeitos. Flags:

- `--gateway`: liga esse modo.
- `--bot-token '${ENV}'`: o token do bot, tirado do Discord Developer Portal, guardado como
  `${ENV_VAR}`. Ative também a intent **Message Content** na página do Bot do app, ou o
  Discord não entrega o texto de uma mensagem que não mencionar o bot.
- `--no-require-mention`: num servidor, por padrão o bot só responde a uma mensagem que o
  @mencione ou responda a algo que ele disse. Passe essa flag para responder a qualquer
  mensagem num canal que ele consiga ver. Numa DM, o bot sempre responde, independente
  dessa flag.
- `--max-attachment-mb N`: aumenta ou diminui o limite padrão de 20 MB para essa conexão.

Anexos da própria mensagem, da mensagem que ela responde (assim dá para responder "o que ele
fala?" depois que o áudio já chegou), e de uma mensagem encaminhada ao bot contam todos, e
passam pelo mesmo tratamento de áudio-para-transcrição, documento-para-texto,
imagem-para-visão que um anexo de comando de barra. As mensagens de uma conexão são
respondidas na ordem em que o Discord as entregou. Se a conexão cair, ela reconecta e
retoma sozinha, sem perder nada do que foi dito no intervalo.

### Trocando de modelo

Com os comandos `/model` e `/models`, qualquer pessoa consegue ver ou trocar qual modelo
de IA está respondendo. No Discord, esses comandos chegam ao Pepe pelo comando que você
mesmo registrou (o `/ask` do exemplo acima): tudo que for digitado na opção `prompt:` vira
a mensagem que o Pepe recebe. Eles só funcionam de fato numa conexão em modo `admin` com
`commands` habilitado; em modo `support`, são tratados como texto normal, sem efeito
especial. O `/models` lista os modelos disponíveis para o projeto daquela conexão; já o
`/model` mostra o modelo atual, ou troca para outro:

```text
/model openrouter               # pergunta se a troca vale só para este chat ou para todos
/model openrouter session       # troca só nesta conversa
/model openrouter global        # troca para todo mundo com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da própria conversa. Já
trocar **globalmente**, afetando todo mundo com quem aquela conexão conversa, é privilégio
reservado aos **treinadores**, a mesma lista de confiança que também controla a memória.
Para desativar completamente a troca de modelo por quem não é treinador, defina
`model_switch_locked: true` na conexão.
