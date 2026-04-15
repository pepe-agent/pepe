---
title: Modelos
description: Liga fornecedores compatíveis com OpenAI e define modelos predefinidos e de recurso.
---

## 3. Ligar um modelo

Aponta o Pepe para qualquer endpoint compatível com a OpenAI. Guarda a chave como
uma referência de ambiente para que o segredo em bruto nunca vá parar ao ficheiro de
configuração.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

Vais ver uma confirmação como está:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5-chat)
```

Algumas coisas que vale a pena saber:

- Nomes que coincidem com um fornecedor incorporado, como `openrouter`, usam o
  endpoint predefinido desse fornecedor. Usa `--base-url` só para endpoints
  personalizados.
- Executa `pepe model add NAME` com um nome que não pareça fornecedor para abrir
  o seletor guiado. Escolhe um fornecedor do catálogo, como te autenticar e depois
  um modelo da lista em direto do fornecedor.
- `pepe model providers` lista os fornecedores que o Pepe conhece de origem.
- `pepe model list` mostra cada ligação guardada e assinala a predefinida.
- `pepe model test` envia um pedido real mínimo para confirmar que a ligação
  funciona.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5-chat)...
✓ openrouter works - reply: pong
```

O painel também consegue fazer tudo isto, no seu separador Modelos, se preferires um
formulário à linha de comandos.

### Renomeia uma ligação

```bash
pepe model rename openrouter OR-trabalho
```

Todo agente, cron e valor predefinido que aponte para a ligação continua a
funcionar - renomear só muda o nome apresentado, não o id estável a que cada
referência está realmente amarrada, por isso não há nada para corrigir depois.

### Muda de modelo a meio de uma conversa

`/model` e `/models` funcionam da mesma forma no Telegram, na consola
(`pepe chat`) e no próprio chat do painel - consulta [Telegram](./telegram/)
para a referência completa de comandos. Qualquer pessoa numa conversa
permitida pode trocar o modelo só para a sua sessão; um formador (a mesma
lista que rege o `/learn`) também pode trocá-lo para todos.

## A ligação de modelo

`model` nomeia uma ligação que definiste com `pepe model add`. Deixá-la por definir
significa que o agente usa o modelo predefinido do seu âmbito, por isso podes apontar
um conjunto inteiro de agentes para um fornecedor e trocá-los todos ao mudar uma
única predefinição.

Uma ligação de modelo pode transportar uma cadeia de reserva. Quando o modelo
primário do agente falha com um erro transitório (um limite de taxa, um tempo
esgotado, uma quebra de rede ou um 5xx), o runtime desce pela cadeia e volta a tentar
no modelo seguinte, emitindo um evento `failover` enquanto o faz. Um erro grave como
uma chave de API errada ou um pedido mal formado falha de imediato, já que outro
endpoint não o resolveria.

O Pepe fala com os fornecedores através do protocolo Chat Completions da OpenAI, por
isso qualquer endpoint compatível com OpenAI funciona sem alteração de código.

### Faça pela conversa

Um agente com a ferramenta `manage_agent` pode reapontar um modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino tem de
ser uma ligação configurada, e a alteração passa pela barreira de permissão como
qualquer outra edição de configuração.
