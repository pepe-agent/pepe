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

Apenas os eventos `MESSAGE` de uma pessoa são atendidos. As respostas são
publicadas de volta no espaço pela Chat REST API. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/root/googlechat/<slug>
```

Vê [Webhooks](../webhooks/) para os campos partilhados por toda a ligação
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como funciona a rota genérica por dentro.

### Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` com `commands`
ativado; no `support`, são texto simples. `/models` lista os modelos
disponíveis para a empresa desta ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** está reservado a **formadores**, a mesma lista que
rege a memória. Define `model_switch_locked: true` na ligação para desativar
por completo a mudança de modelo para quem não é formador.
