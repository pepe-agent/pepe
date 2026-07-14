---
title: Google Chat
description: Liga uma aplicação do Google Chat a um agente do Pepe.
---

## Google Chat

O Google Chat publica eventos de espaço no URL de retorno. Configura pela
configuração guiada (ou pelo painel):

```bash
pepe setup
```

O `config` de uma ligação contém:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas
  respostas. Guarda-o como `${ENV_VAR}` e renova-o por fora.
- `project_number`: o número do projeto Cloud em que a aplicação do Chat
  está registada. Na página de configuração da aplicação do Chat, define
  **Authentication Audience** como **Project Number** — a outra opção (HTTP
  endpoint URL) envia um token com formato diferente, que o Pepe não valida,
  e todas as mensagens recebidas seriam rejeitadas.

Apenas os eventos `MESSAGE` de uma pessoa são atendidos. As respostas são
publicadas de volta no espaço pela Chat REST API. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Autenticação de entrada

Cada pedido recebido traz um token assinado pela Google no `Authorization:
Bearer`, e o Pepe valida-o (assinatura contra as chaves publicadas pela
Google, emissor, e um audience igual a `project_number`) antes de o agente
ver seja o que for. Assim o endpoint aceita `POST`s diretamente da Google —
sem precisar de proxy validador. Se o teu proxy já faz essa verificação,
define `trust_proxy: true` na ligação para saltar a do Pepe.

Vê [Webhooks](../webhooks/) para os campos partilhados por toda a ligação
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como funciona a rota genérica por dentro.

### Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` com `commands`
ativado; no `support`, são texto simples. `/models` lista os modelos
disponíveis para o projeto desta ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** está reservado a **formadores**, a mesma lista que
rege a memória. Define `model_switch_locked: true` na ligação para desativar
por completo a mudança de modelo para quem não é formador.
