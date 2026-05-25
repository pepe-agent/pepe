---
title: Discord
description: Ligue o endpoint de Interactions de um app do Discord a um agente do Pepe.
---

## Discord

O Discord é ligado pelo endpoint de Interactions (comandos de barra),
então ele se encaixa no gateway de webhook em vez de uma conexão persistente.
Configure pela configuração guiada (ou pelo painel):

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

O comando que você registrou (`/ask` acima) carrega qualquer texto que você
colocar na opção `prompt:` dele, então `/model` e `/models` chegam ao Pepe do
mesmo jeito que qualquer outra mensagem, digitados nesse valor. Eles só
disparam numa conexão em modo `admin` com `commands` habilitado; no
`support`, viram texto puro. `/models` lista os modelos disponíveis para a
projeto dessa conexão; `/model` mostra o atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar sua própria sessão;
trocar **globalmente** é reservado para **treinadores**, a mesma lista que
controla a memória. Defina `model_switch_locked: true` na conexão para
desativar totalmente a troca de modelo por quem não é treinador.
