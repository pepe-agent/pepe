---
title: Fetch URL
description: A ferramenta fetch_url de um agente lê o conteúdo real de uma página por omissão, não o HTML em bruto à volta.
---

`fetch_url` é um simples GET por HTTP, mas uma resposta HTML não é devolvida tal como veio: por omissão é reduzida primeiro ao texto legível real da página. Barras de navegação, avisos de cookies, rodapés e marcação publicitária consomem contexto sem nunca serem a resposta ao que o agente foi buscar.

```
Tu: O que diz este artigo do blog sobre o novo lançamento?
    [fetch_url: "https://example.com/blog/new-release"]

Agente: [lê o texto real do artigo, sem a navegação/rodapé do site à volta]
O artigo cobre três alterações: ...
```

## Quando queres a marcação sem processar

Passa `raw: true` para saltar a extração e obter o corpo da resposta exatamente como o servidor o enviou - útil para uma resposta de API, código-fonte, ou uma página de que precisas do HTML literal (atributos, estrutura, dados embutidos), não da sua prosa.

```
fetch_url url: "https://example.com/product/123" raw: true
```

A extração só se aplica a uma resposta `text/html` à partida - um fetch de JSON ou texto simples nunca é tocado. E degrada-se com elegância: uma página sem nada extraível (uma lista de links, uma página que é sobretudo navegação, um documento muito grande) volta ao corpo sem processar automaticamente, o mesmo que `raw: true` te teria dado, em vez de devolver algo enganosamente vazio.

Isto é processamento de texto lexical, não uma chamada a um LLM - sem latência extra, sem custo extra, e funciona da mesma forma independentemente do modelo que o próprio agente esteja a usar.
