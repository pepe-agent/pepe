---
title: Início rápido
description: Instala o Pepe, cria um agente e corre a tua primeira conversa com ele.
---

Bastam poucos comandos para instalares o Pepe, criares um agente e começares a falar com ele. O `pepe setup` segue sempre o caminho mais curto: modelo, chave, primeiro agente e, se quiseres, um canal.

## 1. Instala

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
pepe help
```

## 2. Configura

```bash
pepe setup
```

O assistente guiado trata de escrever `~/.pepe/config.json`. Quando te pedir uma chave, prefere sempre uma referência como `${OPENROUTER_API_KEY}`, para o segredo em si nunca chegar a entrar no ficheiro.

## 3. Fala com ele

```bash
pepe run assistant "que ficheiros existem neste diretório?"
```

Se já tiveres um agente predefinido, podes dispensar o nome:

```bash
pepe run "resume o README em três pontos"
```

E para uma conversa que se prolongue:

```bash
pepe chat assistant
```

O `pepe run` responde uma vez e esquece logo tudo: nada fica guardado para a próxima execução. Se quiseres voltar a uma conversa mais tarde, no terminal, dá um nome à sessão:

```bash
pepe chat assistant --session minha-sessao
```

Sempre que uma ferramenta quiser agir na tua máquina, seja correr um comando ou escrever um ficheiro, o Pepe pede primeiro a tua aprovação.

## 4. Serve a API e o painel

```bash
pepe serve --port 4000
```

O mesmo agente passa agora a estar acessível de três formas:

- Painel local: `http://localhost:4000`
- API compatível com a OpenAI: `POST /v1/chat/completions`
- WebSocket: `ws://localhost:4000/socket/websocket`

Para testares a API:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"olá"}]}'
```

<div class="note"><strong>A API nasce local.</strong> Enquanto não criares um token, só esta máquina consegue chamar <code>/v1</code>, o que significa que mais ninguém chega ao teu agente. Cria um token com <code>pepe token add</code> antes de expores o servidor lá para fora.</div>

## 5. Liga um canal

O Telegram é o teste mais rápido de todos, porque não exige nenhum URL público:

```bash
pepe gateway telegram setup
pepe gateway telegram
```

A partir daí, qualquer pessoa que escreva ao bot está a falar com o mesmo agente. WhatsApp, Slack, Discord, Teams e Google Chat têm cada um a sua página em [Canais](../channels/).

## 6. Automatiza

```bash
pepe cron add
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
```

Usa tarefas agendadas para o que se repete ao longo do tempo, e vigilâncias para seres avisado uma única vez, no momento em que algo que te interessa mudar.

## Próximos passos

- [Agentes e ferramentas](../agents/)
- [API HTTP](../api/)
- [Canais](../channels/)
- [Tarefas agendadas](../scheduled/)
- [Segurança e permissões](../security/)
- [Plugins](../plugins/)
