---
title: WhatsApp
description: Coloca um agente do Pepe atrás do teu número de WhatsApp, através da Cloud API da Meta.
---

## WhatsApp

O WhatsApp assenta na Cloud API da Meta. Ao contrário do Telegram, onde é o próprio Pepe que vai buscar as mensagens, no WhatsApp é a plataforma que **entrega** cada mensagem recebida a um endereço no teu servidor, por isso o Pepe precisa mesmo de estar acessível pela internet. Cada ligação ganha o seu próprio URL na rota de entrada do Pepe:

```
/webhooks/:project/:provider/:slug        ex.:  /webhooks/acme/whatsapp/support
```

O segmento `:project` é `default` quando não usas outros projetos. O próprio Pepe trata do aperto de mão de verificação da Meta nesse URL, e toda a mensagem recebida tem a sua assinatura `X-Hub-Signature-256` verificada contra o app secret antes de o agente sequer correr, por isso um pedido forjado nunca chega a alcançá-lo. A resposta segue de volta pela Graph API, e como é o próprio `pepe serve` que serve esta rota, não há nenhum processo extra a manter.

Podes correr quantas ligações quiseres, cada uma associada ao seu próprio agente, tal como acontece com vários bots do Telegram.

O WhatsApp tem uma linha de comandos própria por ser, de longe, o canal por webhook mais usado. Para adicionar uma ligação:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

As credenciais da ligação, guardadas dentro do seu `config`:

- `phone_number_id`: o id do ponto de envio, tal como consta na aplicação da Meta.
- `access_token`: o token bearer da Graph API, a guardar como `${ENV_VAR}`.
- `app_secret`: usado para verificar o `X-Hub-Signature-256` de entrada, também a guardar como `${ENV_VAR}`.
- `verify_token`: qualquer texto à tua escolha, que a Meta devolve durante o aperto de mão de subscrição; se omitires a opção, usa-se o próprio slug.

Se deixares de fora `--access-token` ou `--app-secret`, a linha de comandos escreve uma referência provisória derivada do slug (por exemplo, `${WA_TOKEN_SUPPORT}` e `${WA_APP_SECRET_SUPPORT}`), para depois preencheres o valor real no teu ambiente. O comando termina por imprimir o URL de retorno e o token de verificação; cola os dois na configuração de webhook da aplicação da Meta, e subscreve o campo `messages`, ou a Meta nunca chega a entregar-te as mensagens de entrada.

```
https://YOUR_HOST/webhooks/default/whatsapp/support
```

Para gerir ligações:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

O `whatsapp list` imprime cada ligação com o respetivo URL de retorno. As restantes opções do `whatsapp add`, `--project`, `--trainers`, `--ttl-min`, `--ephemeral` e `--commands`, correspondem aos campos por ligação descritos acima, e o painel adiciona e edita ligações do WhatsApp na mesma secção Channels.

### Do lado da Meta

Isto faz-se uma vez por número, dentro da tua aplicação da Meta:

1. Cria uma aplicação e adiciona-lhe o produto WhatsApp.
2. Anota o `phone_number_id` do número que estás a ligar.
3. Gera um token de acesso permanente e guarda-o no teu ambiente como `${WA_TOKEN_<SLUG>}`.
4. Copia o App Secret e guarda-o também no teu ambiente, como `${WA_APP_SECRET_<SLUG>}`.
5. Aponta a Callback URL para o slug da tua ligação, introduz o token de verificação, e subscreve o campo `messages`.

### Os dois modos

O `--mode` de uma ligação decide quanto do Pepe fica exposto. A comparação completa está em [Canais](../channels/); para um número de WhatsApp, resume-se a isto:

| | **admin** (o teu) | **support** (voltado para o cliente) |
|---|---|---|
| Comandos de barra | Ligados (`/new` reinicia) | Desligados, tratados como texto simples |
| Quem pode falar | `allowed_numbers`, o teu próprio número | Qualquer pessoa |
| Aprende? (`trainers`) | Tu és formador | `[]`, por isso nunca aprende com um cliente |
| Ferramentas do agente | Completas | Mantém-nas restritas: só ferramentas seguras, já que não há ninguém ali para aprovar uma ação arriscada |
| Sessão | Mantida | Efémera, com um TTL de inatividade |

### A sessão

A sessão fica indexada como `whatsapp:<agent>:<phone>`, a conversa do agente com aquele cliente em concreto, isolada por projeto através do handle do agente. Duas coisas lhe põem fim:

- O agente invoca a ferramenta **`end_session`** quando a troca termina, limpando o contexto para que a próxima mensagem do cliente comece do zero.
- O **TTL de inatividade** (`--ttl-min`, que por omissão nunca expira) despeja uma conversa que ficou muda.

Passar uma conversa a um especialista não exige nenhuma maquinaria extra: basta ao agente chamar `send_to_agent` (vê [Encaminhamento](../routing/)).

<div class="note"><strong>Regra das 24 horas.</strong> A Meta só permite respostas em formato livre dentro das 24 horas seguintes à última mensagem do utilizador. O suporte reativo encaixa nisto sem esforço; já mensagens proativas fora dessa janela exigem modelos pré-aprovados, que este canal não envia.</div>

### Mensagens de voz, fotografias e ficheiros

Uma mensagem de voz chega como **texto**: é transcrita à entrada, antes de o agente correr, pelo que quem faz a pergunta a falar recebe resposta à pergunta e não um comentário sobre um ficheiro de áudio. Um PDF ou uma folha de cálculo chegam já com o conteúdo lido, ao lado do que foi dito sobre eles. Uma fotografia chega ao modelo como imagem, quando o modelo do agente tem visão.

Nada disto exige credenciais novas. A Meta entrega um id de média e o Pepe resolve-o na Graph API com o mesmo token de acesso que a ligação já usa. A Meta limita a média recebida por tipo (16 MB para áudio e vídeo, 5 MB para imagens, 100 MB para documentos), e o Pepe aplica o seu próprio limite de 20 MB por cima, por isso vale o menor dos dois. Se não houver nenhuma rota de transcrição configurada nem possível de deduzir, o ficheiro fica no workspace do agente e o agente é informado de onde está. Ver [Mensagens de voz](../voice/) e [Documentos](../documents/).

### Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` (vê a comparação acima); em `support`, tornam-se texto simples como qualquer outro comando de barra. O `/models` lista os modelos disponíveis para o projeto dessa ligação; o `/model` mostra o que está ativo, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão; mudá-lo **globalmente** fica reservado aos **formadores**, a mesma lista que controla a memória. Define `model_switch_locked: true` na ligação para desligar por completo a troca de modelo para quem não é formador. O WhatsApp não tem um seletor com botões como o do Telegram; aqui é sempre por comando escrito.
