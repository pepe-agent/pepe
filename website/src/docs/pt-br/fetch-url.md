---
title: Fetch URL
description: Por padrão, a ferramenta fetch_url de um agente devolve o conteúdo de leitura de uma página, não o HTML bruto em volta dele.
---

`fetch_url` faz um GET HTTP simples, mas não devolve uma resposta HTML do jeito que ela chegou: por padrão, o texto é destilado antes, até sobrar só o que a página realmente diz. Barra de navegação, aviso de cookies, rodapé, marcação de anúncio, nada disso vai virar a resposta que o agente foi buscar, então só lotaria a conversa à toa.

```
Você: O que esse post do blog fala sobre o novo lançamento?
     [fetch_url: "https://example.com/blog/new-release"]

Agente: [lê o texto de fato do artigo, sem a navegação nem o rodapé do site]
O post cobre três mudanças: ...
```

## Quando você precisa da marcação crua

Passe `raw: true` para pular a extração e receber o corpo da resposta exatamente como o servidor mandou. Serve para uma resposta de API, um código-fonte, ou uma página em que o que importa é o HTML literal (atributos, estrutura, dados embutidos), não a prosa dela.

```
fetch_url url: "https://example.com/product/123" raw: true
```

A extração só entra em cena quando a resposta é `text/html`; um retorno em JSON ou texto puro passa direto, sem nenhum tratamento. E quando não há o que extrair, seja porque a página é uma lista de links, é majoritariamente navegação, ou é grande demais, ela cai sozinha para o corpo bruto, o mesmo resultado que `raw: true` te daria, em vez de devolver algo enganosamente vazio.

Essa limpeza é processamento de texto puro, não uma chamada a modelo nenhum: não custa tempo, não custa dinheiro, e funciona do mesmo jeito não importa qual modelo o agente esteja usando.
