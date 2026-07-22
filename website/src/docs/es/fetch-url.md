---
title: Fetch URL
description: La herramienta fetch_url de un agente lee el contenido real de una página por defecto, no el HTML crudo alrededor.
---

`fetch_url` es un simple GET por HTTP, pero una respuesta HTML no se devuelve tal cual: por defecto se reduce primero al texto legible real de la página. Las barras de navegación, avisos de cookies, pies de página y marcado publicitario consumen contexto sin nunca ser la respuesta a lo que el agente fue a buscar.

```
Tú: ¿Qué dice esta entrada del blog sobre el nuevo lanzamiento?
    [fetch_url: "https://example.com/blog/new-release"]

Agente: [lee el texto real del artículo, sin la navegación/pie de página del sitio alrededor]
La entrada cubre tres cambios: ...
```

## Cuando quieres el marcado sin procesar

Pasa `raw: true` para saltar la extracción y obtener el cuerpo de la respuesta exactamente como lo envió el servidor - útil para una respuesta de API, código fuente, o una página de la que necesitas el HTML literal (atributos, estructura, datos incrustados), no su prosa.

```
fetch_url url: "https://example.com/product/123" raw: true
```

La extracción solo se aplica a una respuesta `text/html` en primer lugar - un fetch de JSON o texto plano nunca se toca. Y se degrada con gracia: una página sin nada extraíble (una lista de enlaces, una página que es mayormente navegación, un documento muy grande) cae de vuelta al cuerpo sin procesar automáticamente, lo mismo que `raw: true` te habría dado, en vez de devolver algo engañosamente vacío.

Esto es procesamiento de texto léxico, no una llamada a un LLM - sin latencia extra, sin costo extra, y funciona igual sin importar qué modelo esté usando el propio agente.
