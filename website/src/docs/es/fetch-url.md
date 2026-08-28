---
title: Fetch URL
description: La herramienta fetch_url de un agente lee, por defecto, el contenido real de una página, no el HTML crudo que la rodea.
---

`fetch_url` no es más que un GET por HTTP, pero cuando la respuesta es HTML
no se entrega tal cual: por defecto, primero se reduce al texto legible real
de la página. Barras de navegación, avisos de cookies, pies de página y
marcado publicitario solo ocuparían espacio en la conversación sin aportar
nada a lo que el agente en realidad fue a buscar.

```
Tú: ¿Qué dice esta entrada del blog sobre el nuevo lanzamiento?
    [fetch_url: "https://example.com/blog/new-release"]

Agente: [lee el texto real del artículo, sin la navegación/pie de página del sitio alrededor]
La entrada cubre tres cambios: ...
```

## Si prefieres el marcado sin procesar

Si pasas `raw: true`, te saltas la extracción y recibes el cuerpo de la
respuesta exactamente como lo mandó el servidor. Esto sirve para una
respuesta de API, código fuente, o cualquier página donde lo que necesitas es
el HTML literal (atributos, estructura, datos incrustados) y no su prosa.

```
fetch_url url: "https://example.com/product/123" raw: true
```

La extracción, para empezar, solo se aplica a una respuesta `text/html`; un
fetch de JSON o de texto plano queda intacto siempre. Y cuando no hay nada
que extraer (una página que es solo una lista de enlaces, casi puro menú de
navegación, o un documento enorme) el sistema no falla de forma confusa: cae
automáticamente al cuerpo sin procesar, el mismo resultado que habrías
obtenido con `raw: true`, en vez de devolverte algo vacío que induzca a
error.

Toda esta limpieza es procesamiento de texto plano, no una llamada al
modelo: no suma ni retraso ni costo, y funciona exactamente igual sin
importar qué modelo esté usando el agente.
