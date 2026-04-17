---
title: Modelos
description: Conecte provedores compatíveis com OpenAI e defina modelos padrão e de fallback.
---

## 3. Conectar um modelo

Aponte o Pepe para qualquer endpoint compatível com a OpenAI. Guarde a chave como
uma referência de ambiente para que o segredo cru nunca caia no arquivo de
configuração.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

Você verá uma confirmação assim:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5-chat)
```

Algumas coisas que vale saber:

- Nomes que batem com um provedor embutido, como `openrouter`, usam o endpoint
  padrão desse provedor. Use `--base-url` só para endpoints personalizados.
- Rode `pepe model add NAME` com um nome que não pareça provedor para abrir o
  seletor guiado. Escolha um provedor do catálogo, como se autenticar e depois um
  modelo da lista ao vivo do provedor.
- `pepe model providers` lista os provedores que o Pepe conhece de fábrica.
- `pepe model list` mostra cada conexão salva e marca a padrão.
- `pepe model test` envia uma requisição real mínima para confirmar que a conexão
  funciona.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5-chat)...
✓ openrouter works - reply: pong
```

O painel também faz tudo isso, na aba Modelos, se você preferir um formulário à
linha de comando.

### Renomear uma conexão

```bash
pepe model rename openrouter OR-trabalho
```

Todo agente, cron e padrão que aponta pra conexão continua funcionando:
renomear só muda o nome de exibição, não o id estável que cada referência
guarda de verdade, então não tem nada pra consertar depois.

### Trocar de modelo no meio da conversa

`/model` e `/models` funcionam do mesmo jeito no Telegram, no console
(`pepe chat`) e no próprio chat do painel; veja [Telegram](../telegram/) pra
a referência completa de comandos. Qualquer um numa conversa permitida pode
trocar o modelo só pra sua sessão; um treinador (a mesma lista que controla
`/learn`) também pode trocar pra todo mundo.

## A conexão de modelo

`model` nomeia uma conexão que você definiu com `pepe model add`. Deixá-lo sem
definir significa que o agente usa o modelo padrão do seu escopo, então você pode
apontar um conjunto inteiro de agentes para um provedor e trocar todos mudando um
único padrão.

Uma conexão de modelo pode carregar uma cadeia de reserva. Quando o modelo primário
do agente falha com um erro transitório (um limite de taxa, um tempo esgotado, uma
queda de rede ou um 5xx), o runtime desce pela cadeia e tenta de novo no próximo
modelo, emitindo um evento `failover` enquanto o faz. Um erro grave como uma chave de
API errada ou uma requisição mal formada falha na hora, já que outro endpoint não
resolveria.

O Pepe fala com os provedores pelo protocolo Chat Completions da OpenAI, então
qualquer endpoint compatível com OpenAI funciona sem mudança de código.

Uma sessão também pode descer sozinha pra um modelo mais barato automaticamente,
no seu próprio primeiro turno, quando uma chamada rápida de triagem julga a
conversa simples o bastante. Veja [Roteamento de modelo por complexidade](../agents/#roteamento-de-modelo-por-complexidade).

### Faça pela conversa

Um agente com a ferramenta `manage_agent` pode reapontar um modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino precisa
ser uma conexão configurada, e a mudança passa pela barreira de permissão como
qualquer outra edição de configuração.
