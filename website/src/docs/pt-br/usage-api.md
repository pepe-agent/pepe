---
title: API de consumo
description: Leia por HTTP quanto foi gasto, com um token de escopo restrito, por mensagem, por chamada de modelo, com ou sem o seu markup aplicado.
---

É em cima do `/v1/usage` que você constrói uma integração de cobrança: ele
lê o que já foi gasto, via HTTP, com um token que enxerga os números mas não
roda nada. A pergunta que a cobrança realmente faz não é "quanto custou
esse mês", e sim "quanto custou *aquela mensagem ali*, e por quê"; é essa
que o endpoint responde.

São quatro endpoints, quatro níveis de zoom sobre o mesmo livro-razão:

| Endpoint | Uma linha por |
| --- | --- |
| `GET /v1/usage` | intervalo de tempo (hora, dia, semana, mês, ano) |
| `GET /v1/usage/events` | chamada de modelo |
| `GET /v1/usage/runs` | mensagem recebida |
| `GET /v1/usage/runs/:id` | aquela mensagem, chamada por chamada |

Todos usam o mesmo cabeçalho `Authorization: Bearer pepe_...` do resto da
[API HTTP](../api/), e só devolvem dados dos projetos que o token consegue
alcançar. Para entender como os números por trás disso são calculados, veja
[Cobrança e limites](../billing/).

## Um token que só lê

Por padrão, um token pode rodar agentes mas **não** consegue ler consumo, a
menos que você libere isso explicitamente, então nada do que já foi emitido
muda de comportamento. Um token de cobrança somente leitura se cria assim:

```bash
pepe token add --project acme --no-chat --usage --prices billable --label "cobrança acme"
```

Com ele dá para chamar `/v1/usage`, mas não `/v1/chat/completions`; ele
enxerga só o projeto `acme`, e só o valor que o cliente efetivamente paga.
Dá para entregar isso ao financeiro de um cliente sem junto entregar uma
credencial capaz de gastar o seu orçamento de modelo.

As quatro permissões:

| Flag | Padrão | O que libera |
| --- | --- | --- |
| `--chat` / `--no-chat` | ligado | rodar agentes (`/v1/chat/completions`, o WebSocket) |
| `--usage` | desligado | ler o `/v1/usage` |
| `--prices` | `billable` | quanto dos valores uma leitura revela |
| `--content` | desligado | o detalhe de uma execução pode trazer junto o prompt e os argumentos/saída das ferramentas |

Dá para mudar isso depois sem rotacionar o segredo, então a integração do
cliente continua funcionando o tempo todo, mesmo enquanto o que ela enxerga
muda:

```bash
pepe token permissions abc123 --prices list
pepe token permissions abc123 --no-usage
```

Esses mesmos campos aparecem nos cards de token do painel, em **Tokens**, e
um agente de confiança com a ferramenta `manage_token` também consegue criar
um direto pela conversa. Um token de **widget**, por outro lado, nunca lê
consumo: ele fica exposto no código-fonte público de uma página.

## Quanto ele consegue ver dos valores

Toda chamada medida guarda três números, e é o `--prices` que decide qual
deles uma leitura devolve:

* **`billable`**: preço de tabela multiplicado pelo markup do projeto. É o
  que o cliente paga, é o padrão, e é o único valor que o token de um
  cliente deveria ter acesso.
* **`list`**: os mesmos tokens, mas ao preço puro do modelo, sem nenhum
  markup em cima.
* **`all`**: os dois juntos, mais `cost` (o que você de fato pagou) e
  `margin`. Essa é a sua própria visão, interna.

`billable` e `list` se excluem, não se somam: mostrar os dois ao mesmo tempo
revelaria a razão entre eles, e essa razão é justamente o seu markup, a sua
margem. Um token com permissão `list` vê preço de tabela *no lugar* do
billable, nunca os dois.

Quem decide qual desses três aparece é o token, nunca a requisição: um
cliente que chama `?prices=all` recebe de volta a visão que o próprio token
tem, e não a que pediu na URL.

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

`granularity` aceita `hour`, `day`, `week`, `month` ou `year`, e `limit`
define quantos intervalos voltam na resposta (60 por padrão).

Somar um agregado exige ler cada entrada da janela inteira, então, sem um
`from` explícito, o endpoint assume os **últimos 90 dias** em vez do
histórico completo. A janela realmente usada volta no campo `period`, então
nenhum relatório acaba cobrindo, em silêncio, menos período do que você
imagina. Peça mais quando precisar: `from=0` traz tudo. Um token com
permissão `all` ganha ainda `subscriptions` e `margin` no nível raiz, além
de um `markup` em cada entrada de `by_project`.

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

Para a próxima página, devolva o `next_cursor` recebido como `cursor` na
próxima chamada. A paginação roda sobre um id opaco de linha em vez do
timestamp porque `at` só tem granularidade de um segundo, e uma virada de
página caindo bem dentro de um segundo movimentado acabaria perdendo linhas
ou repetindo elas.

## Uma linha por mensagem

Esse é o endpoint que a maioria das integrações realmente quer. Uma única
mensagem recebida costuma gerar várias chamadas de modelo: o agente
responde, chama uma ferramenta, recebe o resultado dela, chama outra, e só
então responde de novo. O `/v1/usage/runs` reúne todas essas chamadas de
volta na mensagem que as originou.

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

`source` indica o que disparou a execução (`telegram`, `api`, `cron`,
`flow`, e por aí vai), `outcome` é `ok` ou `error`, e `ms` mostra quanto
tempo a mensagem inteira levou.

Vale reparar no que `calls: 4` e `tool_calls: 3` dizem juntos: uma ferramenta
em si não custa tokens; o que encarece uma mensagem é o número de chamadas
de modelo, já que cada nova iteração reenvia um contexto que o resultado da
ferramenta anterior acabou de deixar maior. É exatamente por isso que a
execução, e não a ferramenta isolada, é a unidade que vale a pena olhar.

## Uma mensagem, chamada por chamada

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.exemplo.com/v1/usage/runs/1785312000123456"
```

Devolve os mesmos campos da linha de lista, mais um `breakdown`: cada
chamada de modelo daquela execução, na ordem em que aconteceu, com tokens,
acertos de cache e valores próprios. É essa a resposta para "por que essa
mensagem custou o que custou".

Um token criado com `--content` recebe também um objeto `content`, trazendo
o prompt e os argumentos/saída de cada ferramenta usada. Sem essa flag, a
chave `content` nem aparece. Isso vem desligado por padrão de propósito: um
relatório de consumo é uma fatura, não uma transcrição da conversa. Esse
conteúdo vem do [trace](../traces/) da execução, que é podado por projeto ao
longo do tempo, então uma execução velha o bastante devolve `content: null`
em vez de fingir que nunca teve conteúdo algum.

## Filtros

Cada endpoint aceita os filtros que fazem sentido para ele:

| Parâmetro | Onde | Significado |
| --- | --- | --- |
| `project` | todos | um projeto, e só um que o token já alcança |
| `agent` | todos | o gasto de um agente |
| `model` | resumo, eventos | uma conexão de modelo |
| `source` | todos | `telegram`, `api`, `cron`, `flow`, … |
| `session` | todos | uma conversa |
| `run_id` | resumo, eventos | as chamadas de uma mensagem |
| `from` / `to` | todos | segundos unix, `[from, to)` |
| `limit` | todos | tamanho da página (máx. 1000) |
| `cursor` | eventos, execuções | o `next_cursor` da página anterior |
| `granularity` | resumo | `hour`, `day`, `week`, `month`, `year` |

Um filtro só consegue estreitar o que o token já alcançava, nunca ampliar.
Nomear um projeto fora do escopo dele resulta em **403**, não num resultado
vazio, e um token travado a um único agente continua restrito a ele
independente do que `agent=` disser na URL. Já `model=` e `run_id=` em
`/runs` dão **400**: uma execução não tem um único modelo associado, e um id
de execução específico é papel do `/runs/:id`; um filtro que simplesmente
não faz nada devolveria um relatório que você acreditaria mais restrito do
que realmente é.

## Erros

| Status | Quando |
| --- | --- |
| 401 | token ausente ou desconhecido |
| 403 | o token não tem permissão de leitura de consumo, ou pediu um projeto fora do seu alcance |
| 404 | não existe essa execução dentro do escopo do token |
| 400 | um parâmetro inutilizável |

Uma execução pertencente a outro projeto responde **404**, não 403, para
que o endpoint nunca confirme que um id existe em algum lugar que você não
tem como enxergar.
