---
title: API de consumo
description: Leia por HTTP o que foi gasto, com um token com escopo, por mensagem, por chamada de modelo, com ou sem o seu markup.
---

O mesmo token que roda um agente também pode ser criado para fazer o contrário: não rodar nada, e só ler o que foi gasto. É para isso que serve o `/v1/usage`. Ele responde a pergunta que uma integração de cobrança realmente faz, que não é "quanto custou este mês", e sim "quanto custou *aquela mensagem*, e por quê".

Quatro endpoints, quatro níveis de zoom sobre o mesmo ledger:

| Endpoint | Uma linha por |
| --- | --- |
| `GET /v1/usage` | intervalo de tempo (hora, dia, semana, mês, ano) |
| `GET /v1/usage/events` | chamada de modelo |
| `GET /v1/usage/runs` | mensagem recebida |
| `GET /v1/usage/runs/:id` | aquela mensagem, chamada por chamada |

Eles usam o mesmo cabeçalho `Authorization: Bearer pepe_...` do resto da [API HTTP](../api/), e só respondem sobre os projetos que o token alcança. Veja [Cobrança e limites](../billing/) para entender como os números são calculados.

## Um token que só lê

Um token pode rodar agentes e **não** pode ler consumo, a menos que você diga o contrário, então nada do que você já criou muda. Crie um token de cobrança somente leitura assim:

```bash
pepe token add --project acme --no-chat --usage --prices billable --label "cobrança acme"
```

Esse token chama o `/v1/usage`, não chama o `/v1/chat/completions`, enxerga só o projeto `acme` e enxerga só o que o cliente paga. Entregue-o ao sistema financeiro do cliente sem dar junto uma credencial capaz de gastar o seu orçamento de modelo.

As quatro permissões:

| Flag | Padrão | O que libera |
| --- | --- | --- |
| `--chat` / `--no-chat` | ligado | rodar agentes (`/v1/chat/completions`, o WebSocket) |
| `--usage` | desligado | ler o `/v1/usage` |
| `--prices` | `billable` | quanto dos valores uma leitura mostra |
| `--content` | desligado | o detalhe de uma execução pode incluir o prompt e os argumentos e a saída das ferramentas |

Mude depois sem rotacionar o segredo, para que a integração do cliente continue funcionando enquanto o que ela pode ver muda:

```bash
pepe token permissions abc123 --prices list
pepe token permissions abc123 --no-usage
```

Os mesmos campos estão nos cards de token do dashboard, em **Tokens**, e um agente de confiança com a ferramenta `manage_token` consegue criar um pela conversa. Um token de **widget** nunca pode ler consumo: ele fica no código-fonte público da página.

## Quanto ele enxerga dos valores

Toda chamada medida tem três números, e o `--prices` escolhe qual deles uma leitura devolve:

* **`billable`**: preço de tabela × o markup do projeto. O que o cliente paga. O padrão, e o único que o token de um cliente deveria ter.
* **`list`**: os mesmos tokens ao preço do modelo, sem markup aplicado.
* **`all`**: os dois, mais `cost` (o que você pagou de fato) e `margin`. A sua própria visão.

`billable` e `list` são exclusivos, não cumulativos. Mostrar os dois entrega a razão entre eles, que é o markup, que é a margem. Um token com `list` está vendo preços de tabela *no lugar*, não além.

Quem decide isso é o token, nunca a requisição. Um cliente que chama `?prices=all` recebe de volta a visão do próprio token, não a que pediu.

## Agregados

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.exemplo.com/v1/usage?granularity=day&limit=30"
```

```json
{
  "object": "usage.summary",
  "granularity": "day",
  "currency": "BRL",
  "scope": { "projects": ["acme"], "agent": null },
  "period": { "from": 1777536000, "to": null },
  "totals": { "calls": 412, "input_tokens": 918204, "output_tokens": 61233, "total_tokens": 979437, "billable": 13.55 },
  "buckets": [{ "key": "2026-07-28", "calls": 61, "input_tokens": 140233, "output_tokens": 9120, "total_tokens": 149353, "billable": 2.06 }],
  "by_model": [],
  "by_agent": [],
  "by_project": []
}
```

`granularity` é `hour`, `day`, `week`, `month` ou `year`, e `limit` limita quantos intervalos voltam (60 por padrão).

Um agregado precisa ler cada entrada da janela para somá-la, então, sem `from`, este endpoint assume os **últimos 90 dias** em vez do histórico inteiro. A janela usada volta em `period`, para que um relatório nunca cubra menos do que você imagina, em silêncio. Peça mais sempre que precisar: `from=0` é tudo. Um token `all` recebe ainda `subscriptions` e `margin` no topo, e um `markup` em cada entrada de `by_project`.

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

Devolva o `next_cursor` como `cursor` para pedir a próxima página. A paginação usa um id opaco de linha em vez do timestamp, porque `at` tem granularidade de um segundo e uma virada de página caindo dentro de um segundo movimentado perderia linhas ou repetiria linhas.

## Uma linha por mensagem

É o endpoint que a maioria das integrações quer. Uma única mensagem recebida costuma custar várias chamadas de modelo: o agente responde, chama uma ferramenta, recebe o resultado, chama outra e responde de novo. O `/v1/usage/runs` reagrupa essas chamadas na mensagem que as causou.

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

`source` é o que disparou a execução (`telegram`, `api`, `cron`, `flow` e assim por diante), `outcome` é `ok` ou `error`, e `ms` é quanto a mensagem inteira demorou.

Repare no que `calls: 4` e `tool_calls: 3` dizem juntos. Uma ferramenta não custa tokens por si; o que encarece uma mensagem é o número de chamadas de modelo, porque cada iteração reenvia um contexto que o resultado da ferramenta anterior acabou de aumentar. É por isso que a execução, e não a ferramenta, é a unidade que vale a pena ler.

## Uma mensagem, chamada por chamada

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.exemplo.com/v1/usage/runs/1785312000123456"
```

Devolve os mesmos campos da linha da lista, mais `breakdown`: cada chamada de modelo daquela execução, em ordem, com os próprios tokens, acertos de cache e valores. É a resposta para "por que essa mensagem custou tanto".

Um token criado com `--content` recebe também um objeto `content` com o prompt e os argumentos e a saída de cada ferramenta. Sem ele não existe nem a chave `content`. Desligado por padrão de propósito: um relatório de consumo é uma fatura, e uma fatura não é uma transcrição. O conteúdo também vem do [trace](../traces/) da execução, que é podado por projeto, então uma execução antiga o bastante devolve `content: null` em vez de fingir que nunca teve conteúdo.

## Filtros

Cada endpoint aceita os que fazem sentido para ele:

| Parâmetro | Onde | Significado |
| --- | --- | --- |
| `project` | todos | um projeto, e apenas um que o token já alcança |
| `agent` | todos | o gasto de um agente |
| `model` | resumo, eventos | uma conexão de modelo |
| `source` | todos | `telegram`, `api`, `cron`, `flow`, … |
| `session` | todos | uma conversa |
| `run_id` | resumo, eventos | as chamadas de uma mensagem |
| `from` / `to` | todos | segundos unix, `[from, to)` |
| `limit` | todos | tamanho da página (máx. 1000) |
| `cursor` | eventos, execuções | o `next_cursor` da página anterior |
| `granularity` | resumo | `hour`, `day`, `week`, `month`, `year` |

Um filtro só consegue estreitar o que o token já alcança. Nomear um projeto fora do escopo dele é **403**, não um resultado vazio, e um token travado em um agente continua nesse agente, diga o que disser o `agent=`. `model=` e `run_id=` no `/runs` são **400**: uma execução não tem um único modelo, um id de execução é para o `/runs/:id`, e um filtro que silenciosamente não faz nada devolve um relatório que você acreditaria ser mais estreito do que é.

## Erros

| Status | Quando |
| --- | --- |
| 401 | token ausente ou desconhecido |
| 403 | o token não pode ler consumo, ou pediu um projeto que não alcança |
| 404 | não existe essa execução dentro do escopo do token |
| 400 | um parâmetro inutilizável |

Uma execução de outro projeto responde **404** em vez de 403, para que o endpoint nunca confirme que um id existe em algum lugar que você não pode ver.
