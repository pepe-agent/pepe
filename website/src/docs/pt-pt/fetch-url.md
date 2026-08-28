---
title: Fetch URL
description: A ferramenta fetch_url de um agente devolve, por omissão, o conteúdo legível de uma página, não o HTML em bruto à sua volta.
---

`fetch_url` faz um simples GET HTTP, só que uma resposta em HTML não volta tal como veio: por omissão, é primeiro reduzida ao texto que a página realmente dá para ler. Barras de navegação, avisos de cookies, rodapés e blocos de publicidade só ocupariam espaço na conversa, sem nunca serem a resposta que o agente foi buscar.

```
Tu: O que diz este artigo do blog sobre o novo lançamento?
    [fetch_url: "https://example.com/blog/new-release"]

Agente: [lê o texto verdadeiro do artigo, sem a navegação nem o rodapé do site]
O artigo aborda três alterações: ...
```

## Quando preferes o HTML em bruto

Passa `raw: true` para saltar a extração e receber o corpo da resposta exatamente como o servidor o enviou. Serve para uma resposta de API, código-fonte, ou uma página de que precises do HTML literal (atributos, estrutura, dados embutidos), e não da sua prosa.

```
fetch_url url: "https://example.com/product/123" raw: true
```

A extração só entra em jogo para uma resposta `text/html`; um pedido a JSON ou a texto simples passa sempre incólume. E quando não há nada para extrair (uma página feita de links, uma que é sobretudo navegação, um documento enorme), cai de volta para o corpo em bruto sozinha, o mesmo que obterias com `raw: true`, em vez de devolver algo enganosamente vazio.

Esta limpeza é processamento de texto puro, não uma chamada a um modelo: não acrescenta atraso nem custo, e funciona sempre da mesma forma, seja qual for o modelo que o próprio agente esteja a usar.
