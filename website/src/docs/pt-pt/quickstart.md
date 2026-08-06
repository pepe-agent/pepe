---
title: Início rápido
description: Instala o Pepe, cria um agente e corre a primeira conversa.
---

Em poucos comandos instalas o Pepe, crias um agente e falas com ele. `pepe setup`
segue o caminho curto: modelo, chave, primeiro agente e canal opcional.

## 1. Instala

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
pepe help
```

## 2. Configura

```bash
pepe setup
```

O assistente escreve `~/.pepe/config.json`. Quando pedir uma chave, prefere uma
referência como `${OPENROUTER_API_KEY}` para manter o segredo fora do ficheiro.

## 3. Fala

```bash
pepe run assistant "que ficheiros existem neste diretório?"
```

Se definiste um agente predefinido, omite o nome:

```bash
pepe run "resume o README em três pontos"
```

Para uma conversa contínua:

```bash
pepe chat assistant
```

`pepe run` responde uma vez e esquece: nada passa para a execução seguinte. Para
retomares uma conversa no terminal mais tarde, dá um nome à sessão:

```bash
pepe chat assistant --session minha-sessao
```

Quando uma ferramenta quiser agir na tua máquina, como correr um comando ou
escrever um ficheiro, o Pepe pede a tua aprovação antes.

## 4. Serve a API e o painel

```bash
pepe serve --port 4000
```

O mesmo agente fica agora acessível em três lugares:

- Painel local: `http://localhost:4000`
- API compatível com OpenAI: `POST /v1/chat/completions`
- WebSocket: `ws://localhost:4000/socket/websocket`

Testa a API:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"olá"}]}'
```

<div class="note"><strong>A API começa local.</strong> Enquanto não criares um token, só esta máquina consegue chamar <code>/v1</code>: ninguém de fora chega ao teu agente. Cria um com <code>pepe token add</code> antes de expores o servidor.</div>

## 5. Liga um canal

Telegram é o teste mais rápido porque não exige URL público:

```bash
pepe gateway telegram setup
pepe gateway telegram
```

Depois disso, quem falar com o bot conversa com o mesmo agente. WhatsApp, Slack,
Discord, Teams e Google Chat estão em [Canais](../channels/).

## 6. Automatiza

```bash
pepe cron add
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
```

Usa tarefas agendadas para o que se repete, e vigilâncias para seres avisado uma
única vez quando algo que te importa mudar.

## Próximos passos

- [Agentes e ferramentas](../agents/)
- [API HTTP](../api/)
- [Canais](../channels/)
- [Tarefas agendadas](../scheduled/)
- [Segurança e permissões](../security/)
- [Plugins](../plugins/)
