---
title: Modelos
description: Liga o Pepe a qualquer fornecedor compatível com a OpenAI, escolhe um predefinido e acrescenta alternativas de recurso para quando um fornecedor tiver um mau momento.
---

## 3. Ligar um modelo

O Pepe funciona com qualquer fornecedor que fale o protocolo da OpenAI. Passa-lhe a tua chave como o nome de uma variável de ambiente, para que a chave em si nunca chegue a ser escrita no ficheiro de configuração.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

Vais ver uma confirmação parecida com esta:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5-chat)
```

Vale a pena reter algumas coisas:

- Um nome que coincida com um fornecedor já incorporado, como `openrouter`, usa o endpoint predefinido desse fornecedor; reserva `--base-url` só para endpoints personalizados.
- Se correres `pepe model add NOME` com um nome que não corresponda a nenhum fornecedor conhecido, abre-se um seletor guiado: escolhes um fornecedor do catálogo, decides como te autenticar e depois escolhes um modelo da lista em direto desse fornecedor.
- `pepe model providers` lista os fornecedores que o Pepe já conhece de fábrica.
- `pepe model list` mostra cada ligação guardada e assinala qual é a predefinida.
- `pepe model test` manda um pedido real, mínimo, só para confirmar que a ligação está a funcionar.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5-chat)...
✓ openrouter works - reply: pong
```

O painel também faz tudo isto, no separador Modelos, caso prefiras um formulário à linha de comandos.

### Renomear uma ligação

```bash
pepe model rename openrouter OR-trabalho
```

Todo o agente, cron e predefinição que apontem para essa ligação continuam a funcionar sem qualquer sobressalto: renomear só muda o nome apresentado, nunca o id estável a que cada referência está de facto amarrada, por isso não fica nada por corrigir depois.

### Trocar de modelo a meio de uma conversa

`/model` e `/models` funcionam da mesma maneira no Telegram, na consola (`pepe chat`) e no próprio chat do painel; a referência completa de comandos está em [Telegram](../telegram/). Qualquer pessoa numa conversa permitida pode trocar o modelo só para a sua própria sessão; um formador (a mesma lista de confiança que rege o `/learn`) pode também trocá-lo para todos ao mesmo tempo.

## A ligação de modelo

O campo `model` nomeia uma ligação que definiste com `pepe model add`. Deixá-lo por preencher faz o agente cair no modelo predefinido do seu projeto, o que te permite apontar um conjunto inteiro de agentes para um só fornecedor e trocá-los todos de uma vez, mudando apenas essa predefinição.

Uma ligação de modelo pode ainda transportar uma cadeia de recurso: quando o modelo principal do agente falha com um erro passageiro (um limite de taxa, um tempo esgotado, uma falha de rede ou um 5xx), o Pepe desce pela cadeia e tenta o modelo seguinte, emitindo um evento `failover` nesse momento. Já um erro grave, como uma chave de API errada ou um pedido mal formado, falha logo de imediato, porque nenhum outro endpoint resolveria o problema.

Como o Pepe fala com os fornecedores pelo protocolo Chat Completions da OpenAI, qualquer endpoint compatível funciona sem alterar uma linha de código.

Uma sessão também se pode fazer descer sozinha para um modelo mais barato, logo no seu primeiro turno, quando uma chamada rápida de triagem concluir que a conversa é simples o suficiente para o justificar; ver [Encaminhamento de modelo por complexidade](../agents/#encaminhamento-de-modelo-por-complexidade).

### Fazer isto pela conversa

Um agente com a ferramenta `manage_agent` consegue reapontar um modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino tem de ser uma ligação já configurada, e a mudança passa pela barreira de permissão, como qualquer outra edição de configuração.
