---
title: WhatsApp
description: Conecte webhooks da WhatsApp Cloud API a agentes do Pepe.
---

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
  handshake de assinatura. Se você omitir a opção, o slug é usado.

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
janela precisam de templates de mensagem pré-aprovados, que este canal não
envia.</div>

### Trocando de modelo

`/model` e `/models` só disparam numa conexão em modo `admin` (veja a
comparação de modos em [Channels](../channels/)); no `support`, viram texto
puro como qualquer outro comando de barra. `/models` lista os modelos
disponíveis para a empresa dessa conexão; `/model` mostra o que está ativo
agora, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar sua própria sessão;
trocar **globalmente** é reservado para **treinadores**, a mesma lista que
controla a memória. Defina `model_switch_locked: true` na conexão para
desativar totalmente a troca de modelo por quem não é treinador. O WhatsApp
não tem um seletor com botões como o do Telegram; aqui é só digitado.
