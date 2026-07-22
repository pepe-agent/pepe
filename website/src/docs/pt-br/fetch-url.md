---
title: Fetch URL
description: A ferramenta fetch_url de um agente lê o conteúdo real de uma página por padrão, não o HTML bruto ao redor.
---

`fetch_url` é um GET simples por HTTP, mas uma resposta HTML não volta do jeito que veio: por padrão ela é reduzida primeiro ao texto legível de verdade da página. Barras de navegação, avisos de cookies, rodapés e marcação de anúncio consomem contexto sem nunca serem a resposta pro que o agente foi buscar.

```
Você: O que esse post do blog diz sobre o novo lançamento?
     [fetch_url: "https://example.com/blog/new-release"]

Agente: [lê o texto real do artigo, sem a navegação/rodapé do site ao redor]
O post cobre três mudanças: ...
```

## Quando você quer a marcação sem processar

Passe `raw: true` pra pular a extração e receber o corpo da resposta exatamente como o servidor mandou - útil pra uma resposta de API, código-fonte, ou uma página da qual você precisa do HTML literal (atributos, estrutura, dados embutidos), não da prosa dela.

```
fetch_url url: "https://example.com/product/123" raw: true
```

A extração só se aplica a uma resposta `text/html` de primeira - um fetch de JSON ou texto puro nunca é tocado. E ela degrada com elegância: uma página sem nada extraível (uma lista de links, uma página que é basicamente navegação, um documento muito grande) volta pro corpo sem processar automaticamente, a mesma coisa que `raw: true` teria te dado, em vez de devolver algo vazio de forma enganosa.

Isso é processamento de texto léxico, não uma chamada a um LLM - sem latência extra, sem custo extra, e funciona igual não importa qual modelo o próprio agente esteja usando.
