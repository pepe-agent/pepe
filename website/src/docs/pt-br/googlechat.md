---
title: Google Chat
description: Conecte um app do Google Chat a um agente do Pepe.
---

## Google Chat

O Google Chat publica eventos de espaço na URL de retorno. Configure pela
configuração guiada (ou pelo painel):

```bash
pepe setup
```

O `config` de uma conexão contém:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas
  respostas. Guarde como `${ENV_VAR}` e renove por fora.

Só eventos `MESSAGE` de uma pessoa são atendidos. As respostas são publicadas
de volta no espaço pela Chat REST API. Formato da URL de retorno:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

Veja [Webhooks](../webhooks/) para os campos compartilhados por toda conexão
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como a rota genérica funciona por baixo dos panos.

### Trocando de modelo

`/model` e `/models` só disparam numa conexão em modo `admin` com `commands`
habilitado; no `support`, viram texto puro. `/models` lista os modelos
disponíveis para o projeto dessa conexão; `/model` mostra o atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar sua própria sessão;
trocar **globalmente** é reservado para **treinadores**, a mesma lista que
controla a memória. Defina `model_switch_locked: true` na conexão para
desativar totalmente a troca de modelo por quem não é treinador.
