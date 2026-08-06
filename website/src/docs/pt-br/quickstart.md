---
title: Início rápido
description: Instale o Pepe, crie um agente e rode a primeira conversa.
---

Em poucos comandos você instala o Pepe, cria um agente e conversa com ele. O
`pepe setup` cuida do caminho mais curto: modelo, chave, agente inicial e opções
de canal.

## 1. Instale

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
pepe help
```

## 2. Configure

```bash
pepe setup
```

O assistente guiado cria a configuração em `~/.pepe/config.json`. Quando pedir uma
chave, prefira uma referência como `${OPENROUTER_API_KEY}` para manter o segredo
fora do arquivo.

## 3. Converse

```bash
pepe run assistant "quais arquivos existem neste diretório?"
```

Se você marcou um agente como padrão, pode omitir o nome:

```bash
pepe run "resuma o README em três tópicos"
```

Para uma conversa contínua:

```bash
pepe chat assistant
```

`pepe run` responde uma vez e esquece: nada passa para a próxima execução. Para
retomar uma conversa no terminal mais tarde, dê um nome à sessão:

```bash
pepe chat assistant --session minha-sessao
```

Quando uma ferramenta quiser agir na sua máquina, como rodar um comando ou
escrever um arquivo, o Pepe pede sua aprovação antes.

## 4. Sirva a API e o painel

```bash
pepe serve --port 4000
```

O mesmo agente agora fica acessível em três lugares:

- Painel local: `http://localhost:4000`
- API compatível com OpenAI: `POST /v1/chat/completions`
- WebSocket: `ws://localhost:4000/socket/websocket`

Teste a API:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"olá"}]}'
```

<div class="note"><strong>A API começa local.</strong> Enquanto você não criar um token, só esta máquina consegue chamar <code>/v1</code>: ninguém de fora alcança seu agente. Crie um com <code>pepe token add</code> antes de expor o servidor.</div>

## 5. Conecte um canal

Telegram é o teste mais rápido porque não exige URL pública:

```bash
pepe gateway telegram setup
pepe gateway telegram
```

Depois disso, quem falar com o bot conversa com o mesmo agente. WhatsApp, Slack,
Discord, Teams e Google Chat ficam em [Canais](../channels/).

## 6. Automatize

```bash
pepe cron add
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
```

Use tarefas agendadas para o que se repete, e vigias para ser avisado uma única
vez quando algo que importa mudar.

## Próximos passos

- [Agentes e ferramentas](../agents/)
- [API HTTP](../api/)
- [Canais](../channels/)
- [Tarefas agendadas](../scheduled/)
- [Segurança e permissões](../security/)
- [Plugins](../plugins/)
