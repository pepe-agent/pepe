---
title: Discord
description: Responda comandos de barra no seu servidor do Discord com um agente do Pepe.
---

## Discord

No Discord, as pessoas falam com o agente por um comando de barra (por
exemplo, `/ask`). O Discord entrega esses comandos pelo endpoint de
Interactions, que se encaixa no gateway de webhook do Pepe em vez de uma
conexão persistente. Configure pela configuração guiada (ou pelo painel):

```bash
pepe setup
```

O `config` de uma conexão contém:

- `public_key`: a chave pública do app (hex), para a verificação de assinatura
  Ed25519 exigida.
- `application_id`: usado para publicar a resposta de acompanhamento.

No app do Discord, aponte "Interactions Endpoint URL" para a URL da conexão e
adicione um comando de barra com uma opção de texto (por exemplo
`/ask prompt:...`). O Discord exige um retorno em três segundos, então o Pepe
responde com uma resposta adiada e publica a resposta real como acompanhamento
assim que o agente termina. Formato da URL de retorno:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Veja [Webhooks](../webhooks/) para os campos compartilhados por toda conexão
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como a rota genérica funciona por baixo dos panos.

### Trocando de modelo

Os comandos `/model` e `/models` deixam as pessoas ver ou trocar qual modelo
de IA responde a elas. No Discord, eles chegam ao Pepe pelo comando que você
registrou (`/ask` acima): o que você digitar na opção `prompt:` é a mensagem
que o Pepe vê. Eles só funcionam numa conexão em modo `admin` com `commands`
habilitado; no `support`, são tratados como texto comum. `/models` lista os
modelos disponíveis para o projeto dessa conexão; `/model` mostra o atual, ou
troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da própria
conversa. Trocar **globalmente**, para todos com quem essa conexão fala, é
reservado aos **treinadores**, a mesma lista de confiança que controla a
memória. Defina `model_switch_locked: true` na conexão para desativar
totalmente a troca de modelo por quem não é treinador.
