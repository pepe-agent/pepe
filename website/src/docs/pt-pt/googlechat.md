---
title: Google Chat
description: Coloca um agente do Pepe no Google Chat para a tua equipa falar com ele em espaços e mensagens diretas.
---

## Google Chat

Ao ligares o Google Chat, as pessoas passam a poder falar com o agente tanto
nos espaços de equipa como em mensagens diretas. É o próprio Google Chat que
entrega cada mensagem no URL de retorno do Pepe; configura a ligação pela
configuração guiada, ou diretamente no painel:

```bash
pepe setup
```

O `config` de uma ligação guarda:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas
  respostas. Guarda-o como `${ENV_VAR}` e trata da renovação por fora do
  Pepe.
- `project_number`: o número do projeto Cloud onde a aplicação do Chat está
  registada. Na página de configuração dessa aplicação, define
  **Authentication Audience** como **Project Number**. A outra opção (HTTP
  endpoint URL) envia um token noutro formato, que o Pepe não sabe validar,
  e todas as mensagens recebidas acabariam rejeitadas.

Só os eventos `MESSAGE` vindos de uma pessoa são processados. As respostas
são publicadas de volta no espaço através da Chat REST API. O formato do URL
de retorno é:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Autenticação de entrada

Antes de o agente ver seja o que for, o Pepe confirma que cada pedido recebido
vem mesmo do Google: todo o pedido traz, no cabeçalho `Authorization: Bearer`,
um token assinado pelo Google, e o Pepe valida-o de facto (a assinatura contra
as chaves publicadas pelo Google, o emissor, e uma audiência igual ao
`project_number`). Com isto, o endpoint aceita `POST`s vindos diretamente do
Google, sem precisares de um proxy que faça essa validação por ti. Se o teu
proxy já trata disso, define `trust_proxy: true` na ligação e o Pepe salta a
sua própria verificação.

Consulta [Webhooks](../webhooks/) para os campos comuns a qualquer ligação
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
para perceberes como funciona a rota genérica por dentro.

### Mudar de modelo

Os comandos `/model` e `/models` deixam consultar ou mudar qual o modelo de
IA que responde. Só funcionam numa ligação em modo `admin` com `commands`
ativado; no modo `support` são tratados como texto normal, sem qualquer
efeito especial. O `/models` lista os modelos disponíveis para o projeto
desta ligação; o `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se é para mudar só este chat ou todos
/model openrouter session       # muda só nesta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa autorizada pode mudar o modelo da própria
conversa. Já mudá-lo **globalmente**, para todos com quem a ligação fala,
está reservado aos **formadores**, a mesma lista de confiança que gere a
memória. Define `model_switch_locked: true` na ligação para desligar de vez
a mudança de modelo para quem não é formador.
