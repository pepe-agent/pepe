---
title: Discord
description: Liga o endpoint de Interactions de uma aplicação do Discord a um agente do Pepe.
---

## Discord

O Discord é ligado pelo ponto de acesso de Interactions (comandos de barra),
por isso encaixa-se no gateway de webhook em vez de uma ligação persistente.
Configura pela configuração guiada (ou pelo painel):

```bash
pepe setup
```

O `config` de uma ligação contém:

- `public_key`: a chave pública da aplicação (hex), para a verificação de
  assinatura Ed25519 exigida.
- `application_id`: usado para publicar a resposta de seguimento.

Na aplicação do Discord, aponta "Interactions Endpoint URL" para o URL da
ligação e adiciona um comando de barra com uma opção de texto (por exemplo
`/ask prompt:...`). O Discord exige uma confirmação em três segundos, por isso
o Pepe responde com uma resposta diferida e publica a resposta real como
seguimento assim que o agente termina. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Vê [Webhooks](../webhooks/) para os campos partilhados por toda a ligação
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como funciona a rota genérica por dentro.

### Mudar de modelo

O comando que registaste (`/ask` acima) transporta o texto que colocares na tua
opção `prompt:`; por isso `/model` e `/models` chegam ao Pepe da mesma forma
que qualquer outra mensagem, escritos nesse valor. Só disparam numa ligação em
modo `admin` com `commands` ativado; no `support`, são texto simples.
`/models` lista os modelos disponíveis para o projeto desta ligação; `/model`
mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** está reservado a **formadores**, a mesma lista que
rege a memória. Define `model_switch_locked: true` na ligação para desativar
por completo a mudança de modelo para quem não é formador.
