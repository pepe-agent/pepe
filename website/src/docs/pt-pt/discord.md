---
title: Discord
description: Responde a comandos de barra no teu servidor do Discord com um agente do Pepe.
---

## Discord

No Discord, as pessoas falam com o agente através de um comando de barra (por
exemplo, `/ask`). O Discord entrega esses comandos pelo ponto de acesso de
Interactions, que se encaixa no gateway de webhook do Pepe em vez de uma
ligação persistente. Configura pela configuração guiada (ou pelo painel):

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

Os comandos `/model` e `/models` permitem ver ou mudar o modelo de IA que
responde. No Discord, chegam ao Pepe através do comando que registaste
(`/ask` acima): o que escreveres na opção `prompt:` é a mensagem que o Pepe
vê. Só funcionam numa ligação em modo `admin` com `commands` ativado; no
`support`, são tratados como texto normal. `/models` lista os modelos
disponíveis para o projeto desta ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar o modelo da sua própria
conversa. Mudá-lo **globalmente**, para todos com quem esta ligação fala,
está reservado aos **formadores**, a mesma lista de confiança que rege a
memória. Define `model_switch_locked: true` na ligação para desativar por
completo a mudança de modelo para quem não é formador.
