---
title: Modelos
description: Conecte o Pepe a qualquer provedor de modelo compatível com OpenAI, escolha um padrão e defina reservas que assumem quando um provedor passa por um mau momento.
---

## 3. Conecte um modelo

O Pepe funciona com qualquer provedor que fale o protocolo da OpenAI. Passe a chave como o nome de uma variável de ambiente, para que o valor em si nunca chegue a ser escrito no arquivo de configuração.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

Você vai ver uma confirmação assim:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5-chat)
```

Vale saber algumas coisas:

- Um nome que bate com um provedor já embutido, como `openrouter`, usa o endpoint padrão dele. Use `--base-url` só para endpoints personalizados.
- Rodar `pepe model add NAME` com um nome que não é de nenhum provedor conhecido abre um seletor guiado: você escolhe um provedor do catálogo, escolhe como autenticar e depois escolhe um modelo direto da lista ao vivo do provedor.
- `pepe model providers` lista os provedores que o Pepe já conhece de fábrica.
- `pepe model list` mostra cada conexão salva e marca qual é a padrão.
- `pepe model test` dispara uma requisição real bem pequena só para confirmar que a conexão está de pé.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5-chat)...
✓ openrouter works - reply: pong
```

Prefere um formulário à linha de comando? O painel faz tudo isso também, na aba Modelos.

### Renomeando uma conexão

```bash
pepe model rename openrouter OR-trabalho
```

Todo agente, cron e padrão que aponta para essa conexão continua funcionando sem nenhum ajuste: renomear muda só o nome de exibição, nunca o id estável que cada referência de fato guarda por trás dos panos.

### Trocando de modelo no meio da conversa

`/model` e `/models` funcionam do mesmo jeito no Telegram, no console (`pepe chat`) e no próprio chat do painel; a referência completa de comandos está em [Telegram](../telegram/). Qualquer pessoa numa conversa permitida pode trocar o modelo só da própria sessão; já um treinador (a mesma lista que controla o `/learn`) pode trocar para todo mundo de uma vez.

## A conexão de modelo

`model` nomeia uma conexão que você criou com `pepe model add`. Deixar esse campo vazio faz o agente usar o modelo padrão do seu projeto, e é assim que você aponta um conjunto inteiro de agentes para um único provedor e depois troca todos eles de uma vez, mudando apenas esse padrão.

Uma conexão de modelo pode carregar uma cadeia de reserva. Se o modelo principal do agente falhar com um erro passageiro (limite de taxa, timeout, um soluço de rede, um 5xx), o Pepe desce a cadeia e tenta o próximo modelo, emitindo um evento `failover` nesse processo. Já um erro definitivo, como uma chave de API errada ou uma requisição mal formada, falha na hora, porque trocar de endpoint não resolveria nada mesmo.

O Pepe fala com os provedores pelo protocolo Chat Completions da OpenAI, então qualquer endpoint compatível funciona sem precisar mudar uma linha de código.

Uma sessão também pode descer sozinha para um modelo mais barato, logo no primeiro turno, quando uma chamada rápida de triagem julga que a conversa é simples o bastante para isso. Veja [Roteamento de modelo por complexidade](../agents/#roteamento-de-modelo-por-complexidade).

### Fazendo pela conversa

Um agente com a ferramenta `manage_agent` pode reapontar um modelo que ele mesmo administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino precisa já existir como conexão configurada, e a mudança passa pela barreira de permissão como qualquer outra edição de configuração.
