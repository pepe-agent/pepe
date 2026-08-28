---
title: Discord
description: Responda comandos de barra no seu servidor do Discord com um agente do Pepe.
---

## Discord

No Discord, as pessoas conversam com o agente através de um comando de barra (`/ask`, por
exemplo). Como o Discord entrega esses comandos pelo endpoint de Interactions, e não por
uma conexão persistente, isso se encaixa bem no gateway de webhook do Pepe. A configuração
é feita pelo assistente guiado (ou direto pelo dashboard):

```bash
pepe setup
```

O `config` de uma conexão guarda:

- `public_key`: a chave pública do app (em hex), usada na verificação obrigatória de
  assinatura Ed25519.
- `application_id`: usado para publicar a resposta de acompanhamento.

No aplicativo do Discord, aponte "Interactions Endpoint URL" para a URL dessa conexão, e
crie um comando de barra com uma opção de texto (por exemplo, `/ask prompt:...`). Como o
Discord exige uma confirmação em até três segundos, o Pepe primeiro responde com uma
resposta adiada, e só publica a resposta de verdade como acompanhamento assim que o agente
termina de processar. O formato da URL de retorno é:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Veja [Webhooks](../webhooks/) para conhecer os campos que toda conexão compartilha
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e entender como a
rota genérica funciona por trás disso.

### Trocando de modelo

Com os comandos `/model` e `/models`, qualquer pessoa consegue ver ou trocar qual modelo
de IA está respondendo. No Discord, esses comandos chegam ao Pepe pelo comando que você
mesmo registrou (o `/ask` do exemplo acima): tudo que for digitado na opção `prompt:` vira
a mensagem que o Pepe recebe. Eles só funcionam de fato numa conexão em modo `admin` com
`commands` habilitado; em modo `support`, são tratados como texto normal, sem efeito
especial. O `/models` lista os modelos disponíveis para o projeto daquela conexão; já o
`/model` mostra o modelo atual, ou troca para outro:

```text
/model openrouter               # pergunta se a troca vale só para este chat ou para todos
/model openrouter session       # troca só nesta conversa
/model openrouter global        # troca para todo mundo com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da própria conversa. Já
trocar **globalmente**, afetando todo mundo com quem aquela conexão conversa, é privilégio
reservado aos **treinadores**, a mesma lista de confiança que também controla a memória.
Para desativar completamente a troca de modelo por quem não é treinador, defina
`model_switch_locked: true` na conexão.
