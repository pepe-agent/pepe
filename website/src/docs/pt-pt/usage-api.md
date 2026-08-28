---
title: API de consumo
description: Consulta por HTTP o que foi gasto, com um token de âmbito próprio, mensagem a mensagem ou chamada a chamada, com ou sem a tua margem incluída.
---

O `/v1/usage` é a base para qualquer integração de faturação: lê por HTTP o que foi gasto, com um token que vê os números mas não executa nada. É ele que responde à pergunta que a faturação realmente faz, que não é "quanto custou este mês" mas sim "quanto custou *aquela mensagem*, e porquê".

São quatro endpoints, quatro níveis de detalhe sobre o mesmo ledger:

| Endpoint | Uma linha por |
| --- | --- |
| `GET /v1/usage` | intervalo de tempo (hora, dia, semana, mês, ano) |
| `GET /v1/usage/events` | chamada de modelo |
| `GET /v1/usage/runs` | mensagem recebida |
| `GET /v1/usage/runs/:id` | aquela mensagem em concreto, chamada a chamada |

Todos usam o mesmo cabeçalho `Authorization: Bearer pepe_...` do resto da [API HTTP](../api/), e só respondem sobre os projetos que o token alcança. Para perceberes como os números são calculados, vê [Faturação e limites](../billing/).

## Um token que só lê

Por predefinição um token pode executar agentes mas **não** pode ler consumo, a menos que digas o contrário, por isso nada do que já criaste antes muda. Cria um token de faturação só de leitura assim:

```bash
pepe token add --project acme --no-chat --usage --prices billable --label "faturação acme"
```

Esse token consegue chamar `/v1/usage`, não consegue chamar `/v1/chat/completions`, só vê o projeto `acme`, e só vê o que o cliente paga. Dá-o ao sistema financeiro de um cliente sem lhe entregares também uma credencial capaz de gastar o teu orçamento de modelo.

As quatro permissões:

| Flag | Predefinição | O que autoriza |
| --- | --- | --- |
| `--chat` / `--no-chat` | ligado | executar agentes (`/v1/chat/completions`, o WebSocket) |
| `--usage` | desligado | ler o `/v1/usage` |
| `--prices` | `billable` | que parte dos valores uma leitura mostra |
| `--content` | desligado | o detalhe de uma execução pode incluir o prompt e os argumentos/resultado das ferramentas |

Podes mudá-las mais tarde sem rodar o segredo, para a integração do cliente continuar a funcionar enquanto muda o que ele consegue ver:

```bash
pepe token permissions abc123 --prices list
pepe token permissions abc123 --no-usage
```

Estes mesmos campos aparecem nos cartões de token do painel, em **Tokens**, e um agente de confiança com a ferramenta `manage_token` consegue criar um token destes a partir de uma conversa. Um token de **widget**, esse, nunca pode ler consumo: vive no código-fonte público de uma página.

## Quanto dos valores mostra

Cada chamada medida guarda três números, e é o `--prices` que escolhe qual deles uma leitura devolve:

* **`billable`**: o preço de tabela multiplicado pelo markup do projeto, ou seja, o que o cliente paga. É a predefinição, e o único que o token de um cliente deveria ter.
* **`list`**: os mesmos tokens ao preço do modelo, sem qualquer markup.
* **`all`**: os dois anteriores, mais `cost` (o que pagaste de facto) e `margin`. É a tua própria visão.

`billable` e `list` são exclusivos entre si, nunca cumulativos: mostrar os dois ao mesmo tempo revelaria a razão entre eles, e essa razão é o teu markup, a tua margem. Um token com `list` vê os preços de tabela *em vez de* ver os outros, não além deles.

Quem decide isto é sempre o token, nunca o pedido: um cliente que chama `?prices=all` recebe de volta a visão que o seu próprio token permite, não a que pediu.

## Agregados

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.exemplo.com/v1/usage?granularity=day&limit=30"
```

```json
{
  "object": "usage.summary",
  "granularity": "day",
  "currency": "EUR",
  "scope": { "projects": ["acme"], "agent": null },
  "period": { "from": 1777536000, "to": null },
  "totals": { "calls": 412, "input_tokens": 918204, "output_tokens": 61233, "total_tokens": 979437, "billable": 13.55 },
  "buckets": [{ "key": "2026-07-28", "calls": 61, "input_tokens": 140233, "output_tokens": 9120, "total_tokens": 149353, "billable": 2.06 }],
  "by_model": [],
  "by_agent": [],
  "by_project": []
}
```

`granularity` aceita `hour`, `day`, `week`, `month` ou `year`, e `limit` limita quantos intervalos voltam (60 por predefinição).

Como somar um agregado obriga a ler cada entrada da janela, sem indicares `from` este endpoint assume por omissão os **últimos 90 dias**, em vez do histórico inteiro. A janela realmente usada volta no campo `period`, para que um relatório nunca cubra, em silêncio, menos do que pensas. Pede mais sempre que precisares: `from=0` traz tudo. Um token com `all` recebe ainda `subscriptions` e `margin` no nível de topo, e um `markup` em cada entrada de `by_project`.

## Uma linha por chamada de modelo

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.exemplo.com/v1/usage/events?session=telegram:12345&limit=100"
```

```json
{
  "object": "list",
  "data": [
    {
      "at": 1785312000,
      "project": "acme",
      "agent": "acme/vendas",
      "model": "gpt-4o",
      "run_id": "1785312000123456",
      "session": "telegram:12345",
      "source": "telegram",
      "input_tokens": 4120,
      "output_tokens": 210,
      "cached_input_tokens": 3072,
      "total_tokens": 4330,
      "subscription": false,
      "billable": 0.0231
    }
  ],
  "has_more": true,
  "next_cursor": 84213
}
```

Passa o `next_cursor` de volta como `cursor` para pedires a página seguinte. A paginação assenta num id opaco de linha em vez do timestamp, porque `at` só tem granularidade ao segundo, e uma fronteira de página a cair dentro de um segundo movimentado tanto podia perder linhas como repeti-las.

## Uma linha por mensagem

Este costuma ser o endpoint que mais integrações procuram. Uma única mensagem recebida normalmente custa várias chamadas de modelo seguidas: o agente responde, chama uma ferramenta, recebe o resultado, chama outra e responde de novo. O `/v1/usage/runs` reagrupa essas chamadas todas na mensagem que as originou.

```bash
curl -H "Authorization: Bearer $TOKEN" "https://pepe.exemplo.com/v1/usage/runs?limit=50"
```

```json
{
  "object": "list",
  "data": [
    {
      "id": "1785312000123456",
      "at": 1785312000,
      "project": "acme",
      "agent": "acme/vendas",
      "session": "telegram:12345",
      "source": "telegram",
      "ms": 8412,
      "outcome": "ok",
      "tools": ["web_search", "fetch_url", "write_file"],
      "tool_calls": 3,
      "calls": 4,
      "input_tokens": 18320,
      "output_tokens": 940,
      "total_tokens": 19260,
      "billable": 0.0912
    }
  ],
  "has_more": false,
  "next_cursor": null
}
```

`source` diz o que desencadeou a execução (`telegram`, `api`, `cron`, `flow`, e por aí fora), `outcome` é `ok` ou `error`, e `ms` mede quanto tempo levou a mensagem inteira.

Repara no que `calls: 4` e `tool_calls: 3` dizem juntos. Uma ferramenta, em si, não custa tokens nenhuns; o que encarece uma mensagem é o número de chamadas de modelo, já que cada nova iteração reenvia um contexto que o resultado da ferramenta anterior acabou de tornar maior. É por isso que a execução, e não a ferramenta, é a unidade que vale a pena analisar.

## Uma mensagem, chamada a chamada

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.exemplo.com/v1/usage/runs/1785312000123456"
```

Devolve os mesmos campos da linha de lista, mais um `breakdown`: cada chamada de modelo dessa execução, pela ordem em que aconteceu, com os seus próprios tokens, acertos de cache e valores. É a resposta a "porque é que esta mensagem custou tanto".

Um token criado com `--content` recebe ainda um objeto `content` com o prompt e os argumentos/resultado de cada ferramenta; sem essa permissão, a chave `content` nem sequer existe. Fica desligado por predefinição de propósito: um relatório de consumo é uma fatura, e uma fatura não é uma transcrição. O conteúdo também vem do [trace](../traces/) da própria execução, que vai sendo limpo por projeto, por isso uma execução suficientemente antiga devolve `content: null` em vez de fingir que nunca teve conteúdo nenhum.

## Filtros

Cada endpoint aceita os filtros que fazem sentido para ele:

| Parâmetro | Onde | Significado |
| --- | --- | --- |
| `project` | todos | um projeto, e só um que o token já alcance |
| `agent` | todos | o gasto de um agente |
| `model` | resumo, eventos | uma ligação de modelo |
| `source` | todos | `telegram`, `api`, `cron`, `flow`, … |
| `session` | todos | uma conversa |
| `run_id` | resumo, eventos | as chamadas de uma mensagem |
| `from` / `to` | todos | segundos unix, `[from, to)` |
| `limit` | todos | tamanho da página (máx. 1000) |
| `cursor` | eventos, execuções | o `next_cursor` da página anterior |
| `granularity` | resumo | `hour`, `day`, `week`, `month`, `year` |

Um filtro só consegue estreitar o que o token já alcança: nomear um projeto fora do seu âmbito dá **403**, não um resultado vazio, e um token preso a um agente fica sempre nesse agente, seja lá o que `agent=` disser. Já `model=` e `run_id=` em `/runs` dão **400**, porque uma execução não tem um único modelo, um id de execução é precisamente para o que serve `/runs/:id`, e um filtro que não faz nada em silêncio devolveria um relatório que parecesse mais estreito do que realmente é.

## Erros

| Estado | Quando acontece |
| --- | --- |
| 401 | token em falta ou desconhecido |
| 403 | o token não pode ler consumo, ou pediu um projeto que não alcança |
| 404 | não existe essa execução dentro do âmbito do token |
| 400 | um parâmetro inutilizável |

Uma execução que pertence a outro projeto responde **404**, e não 403, para que este endpoint nunca confirme que um id existe algures que não consegues ver.
