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

`pepe run` é uma execução avulsa e não guarda contexto. Para retomar uma conversa
no terminal, usa uma sessão na consola:

```bash
pepe chat assistant --session minha-sessao
```

Quando uma ferramenta quiser agir na tua máquina, como correr shell ou escrever um
ficheiro, o Pepe pede aprovação antes.

## 4. Serve a API e o painel

```bash
pepe serve --port 4000
```

Isto expõe o mesmo agente em três lugares:

- Painel local: `http://localhost:4000`
- API compatível com OpenAI: `POST /v1/chat/completions`
- WebSocket: `ws://localhost:4000/socket/websocket`

Testa a API:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"olá"}]}'
```

<div class="note"><strong>A API começa local.</strong> Sem tokens, apenas chamadas da própria máquina acedem a <code>/v1</code>. Cria um token com <code>pepe token add</code> antes de expores o servidor.</div>

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

Usa tarefas agendadas para rotinas recorrentes e vigilâncias para avisos únicos
quando uma condição mudar.

## Próximos passos

- [Agentes e ferramentas](../agents/)
- [API HTTP](../api/)
- [Canais](../channels/)
- [Tarefas agendadas](../scheduled/)
- [Segurança e permissões](../security/)
- [Plugins](../plugins/)
