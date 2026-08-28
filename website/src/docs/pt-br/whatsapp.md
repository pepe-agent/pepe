---
title: WhatsApp
description: Coloque um agente do Pepe atrás do seu número de WhatsApp, usando a Cloud API da Meta.
---

## WhatsApp

O WhatsApp funciona em cima da Cloud API da Meta. A diferença para o
Telegram é que ali o próprio Pepe vai buscar as mensagens, enquanto no
WhatsApp é a Meta quem **entrega** cada mensagem recebida a um endereço no
seu servidor, então é o Pepe que precisa estar acessível pela internet.
Cada conexão ganha sua própria URL na rota de entrada:

```
/webhooks/:project/:provider/:slug        ex.:  /webhooks/acme/whatsapp/support
```

O segmento `:project` vale `default` quando você não trabalha com projetos
adicionais. É o próprio Pepe quem responde ao handshake de verificação da
Meta nessa URL, e toda mensagem recebida tem sua assinatura
`X-Hub-Signature-256` conferida contra o app secret antes de qualquer
agente rodar, então uma requisição forjada nunca chega perto do agente. A
resposta sai pela Graph API, e como o `pepe serve` já serve essa rota,
não existe processo extra nenhum para manter rodando.

Dá para manter quantas conexões você quiser, cada uma com seu próprio
agente vinculado, exatamente como se faz com múltiplos bots do Telegram.

Por ser o canal por webhook mais usado, o WhatsApp tem uma linha de comando
própria. Para adicionar uma conexão:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

As credenciais dessa conexão, guardadas dentro do próprio `config` dela:

- `phone_number_id`: o id do ponto de envio, obtido no app da Meta.
- `access_token`: o token bearer da Graph API. Guarde como `${ENV_VAR}`.
- `app_secret`: usado para conferir o `X-Hub-Signature-256` de cada
  mensagem recebida. Guarde também como `${ENV_VAR}`.
- `verify_token`: qualquer texto à sua escolha, devolvido pela Meta durante
  o handshake de assinatura. Se você não passar essa opção, o próprio slug
  é usado no lugar.

Deixando `--access-token` ou `--app-secret` de fora, a linha de comando
grava uma referência provisória derivada do slug (algo como
`${WA_TOKEN_SUPPORT}` e `${WA_APP_SECRET_SUPPORT}`), para você preencher o
valor real no seu ambiente mais tarde. O comando já imprime a URL de
retorno e o token de verificação prontos. Cole os dois na configuração de
webhook do app da Meta e assine o campo `messages`, para que ela realmente
comece a entregar as mensagens recebidas:

```
https://YOUR_HOST/webhooks/default/whatsapp/support
```

Gerenciando conexões já criadas:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

O `whatsapp list` mostra cada conexão junto com a URL de retorno dela. As
outras opções do `whatsapp add` são `--project`, `--trainers`, `--ttl-min`,
`--ephemeral` e `--commands`, cada uma mapeando para o campo
correspondente por conexão descrito acima. O painel também adiciona e edita
conexões do WhatsApp, na mesma seção Channels.

### Do lado da Meta

Uma única vez por número, dentro do seu app da Meta:

1. Crie um app e adicione a ele o produto WhatsApp.
2. Anote o `phone_number_id` do número que você está conectando.
3. Gere um token de acesso permanente e guarde no seu ambiente como
   `${WA_TOKEN_<SLUG>}`.
4. Copie o App Secret e guarde no seu ambiente como
   `${WA_APP_SECRET_<SLUG>}`.
5. Aponte a Callback URL para o slug da sua conexão, informe o token de
   verificação e assine o campo `messages`.

### Os dois modos

É o `--mode` da conexão que decide o quanto do Pepe fica exposto. A
comparação completa está em [Canais](../channels/); para um número de
WhatsApp especificamente, ela se resume a isto:

| | **admin** (o seu) | **support** (voltado ao cliente) |
|---|---|---|
| Comandos de barra | Ligados (`/new` reinicia) | Desligados, viram texto puro |
| Quem pode falar | `allowed_numbers`, só o seu próprio número | Qualquer pessoa |
| Aprende? (`trainers`) | Você entra como treinador | `[]`, nunca aprende com um cliente |
| Ferramentas do agente | Completas | Mantenha restrito: só ferramentas seguras, já que não tem humano ali para aprovar uma ação arriscada |
| Sessão | Persistente | Efêmera, com um TTL de inatividade |

### A sessão

A sessão fica indexada como `whatsapp:<agent>:<phone>`, e representa a
conversa do agente com aquele cliente específico, isolada por projeto
através do handle do agente. Duas coisas encerram essa sessão:

- O agente chama a ferramenta **`end_session`** quando considera a troca
  concluída, o que limpa o contexto para que a próxima mensagem desse
  cliente comece do zero.
- O **TTL de inatividade** (`--ttl-min`; se ausente, nunca expira) descarta
  uma conversa que ficou parada por tempo demais.

Passar uma conversa adiante, para um especialista, não pede nenhuma
máquina extra: basta o próprio agente chamar `send_to_agent`. Veja
[Roteamento](../routing/) para mais detalhes.

<div class="note"><strong>A regra das 24 horas.</strong> A Meta só libera
respostas em formato livre dentro de 24 horas após a última mensagem do
usuário. Suporte reativo se encaixa nessa regra naturalmente; já mensagens
proativas fora dessa janela exigem templates pré-aprovados, algo que esse
canal não envia.</div>

### Trocando de modelo

`/model` e `/models` só funcionam mesmo numa conexão em modo `admin` (veja
a comparação de modos acima); no modo `support`, viram texto puro, iguais a
qualquer outro comando de barra. `/models` lista os modelos disponíveis
para o projeto daquela conexão; `/model` mostra o modelo ativo no momento,
ou troca para outro:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa liberada pode trocar o modelo da própria
sessão; já trocar **globalmente** é privilégio dos **treinadores**, a mesma
lista que também controla a memória. Para desligar essa troca por completo
para quem não é treinador, defina `model_switch_locked: true` na conexão.
Diferente do Telegram, o WhatsApp não tem seletor por botões: aqui a troca
é sempre digitada.
