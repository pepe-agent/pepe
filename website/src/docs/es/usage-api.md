---
title: API de consumo
description: Lee por HTTP lo que se ha gastado, con un token acotado, por mensaje, por llamada al modelo, con o sin tu markup.
---

`/v1/usage` es la base para construir una integración de facturación: expone por HTTP lo que se ha gastado, mediante un token que puede ver las cifras pero no ejecutar nada. Responde a la pregunta que la facturación hace de verdad, que no es "¿cuánto costó este mes?" sino "¿cuánto costó *ese mensaje puntual*, y por qué?".

Son cuatro endpoints, cuatro niveles de detalle sobre el mismo libro de registros:

| Endpoint | Una fila por |
| --- | --- |
| `GET /v1/usage` | intervalo de tiempo (hora, día, semana, mes, año) |
| `GET /v1/usage/events` | llamada al modelo |
| `GET /v1/usage/runs` | mensaje entrante |
| `GET /v1/usage/runs/:id` | ese mensaje, llamada por llamada |

Usan la misma cabecera `Authorization: Bearer pepe_...` que el resto de la [API HTTP](../api/), y solo dan datos de los proyectos que el token puede alcanzar. Para entender cómo se calculan las cifras, revisa [Facturación y límites](../billing/).

## Un token que solo lee

Un token puede ejecutar agentes, y por defecto **no** puede leer el consumo salvo que se lo indiques, así que nada de lo que ya emitiste cambia de comportamiento. Para crear un token de facturación de solo lectura:

```bash
pepe token add --project acme --no-chat --usage --prices billable --label "facturación acme"
```

Ese token puede llamar a `/v1/usage`, no puede llamar a `/v1/chat/completions`, solo ve el proyecto `acme`, y solo ve lo que le corresponde pagar al cliente. Se lo puedes entregar al área financiera de un cliente sin darle de paso una credencial capaz de gastar tu presupuesto de modelo.

Los cuatro permisos:

| Flag | Por defecto | Qué habilita |
| --- | --- | --- |
| `--chat` / `--no-chat` | activado | ejecutar agentes (`/v1/chat/completions`, el WebSocket) |
| `--usage` | desactivado | leer `/v1/usage` |
| `--prices` | `billable` | cuánto de los montos deja ver una lectura |
| `--content` | desactivado | el detalle de una ejecución puede incluir el prompt y los argumentos/salida de las herramientas |

Puedes cambiarlos más adelante sin rotar el secreto, para que la integración del cliente siga funcionando mientras cambia lo que puede ver:

```bash
pepe token permissions abc123 --prices list
pepe token permissions abc123 --no-usage
```

Los mismos campos aparecen en las tarjetas de token del panel, bajo **Tokens**, y un agente de confianza con la herramienta `manage_token` puede crear uno desde la conversación. Un token de **widget** nunca puede leer el consumo, porque queda expuesto en el código fuente público de la página.

## Cuánto del dinero deja ver

Cada llamada medida tiene tres cifras asociadas, y `--prices` decide cuál de ellas devuelve una lectura:

* **`billable`**: el precio de lista multiplicado por el markup del proyecto. Es lo que paga el cliente. Es el valor por defecto, y el único que debería llevar el token de un cliente.
* **`list`**: los mismos tokens al precio del modelo, sin ningún markup aplicado.
* **`all`**: ambos, más `cost` (lo que realmente pagaste) y `margin`. Es tu propia vista, la del operador.

`billable` y `list` son excluyentes entre sí, no acumulativos: mostrar los dos a la vez revelaría la relación entre ambos, y esa relación es justamente tu markup, tu margen. Un token con `list` ve los precios de lista *en lugar de* los facturables, no además.

Esto lo decide el token, nunca la petición: un cliente que llama con `?prices=all` recibe la vista que le corresponde a su propio token, no la que pidió.

## Agregados

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.ejemplo.com/v1/usage?granularity=day&limit=30"
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

`granularity` acepta `hour`, `day`, `week`, `month` o `year`, y `limit` pone un tope a cuántos intervalos devuelve (60 por defecto).

Para sumar un agregado hay que leer cada entrada dentro de su ventana, así que, sin `from`, este endpoint asume por defecto los **últimos 90 días** en lugar de todo el historial. La ventana que realmente usó vuelve en `period`, para que un informe nunca termine cubriendo menos de lo que crees sin que te des cuenta. Pide más cuando lo necesites: `from=0` trae todo. Un token `all` recibe además `subscriptions` y `margin` al nivel superior, y un campo `markup` en cada entrada de `by_project`.

## Una fila por llamada al modelo

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.ejemplo.com/v1/usage/events?session=telegram:12345&limit=100"
```

```json
{
  "object": "list",
  "data": [
    {
      "at": 1785312000,
      "project": "acme",
      "agent": "acme/ventas",
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

Para pedir la página siguiente, devuelve `next_cursor` como `cursor`. La paginación se basa en un id de fila opaco en lugar del timestamp, porque `at` tiene granularidad de un segundo, y un corte de página que cayera justo dentro de un segundo con mucha actividad podría perder filas o repetirlas.

## Una fila por mensaje

Este es el endpoint que la mayoría de las integraciones termina usando. Un solo mensaje entrante suele generar varias llamadas al modelo: el agente responde, llama a una herramienta, recibe el resultado, llama a otra, y responde de nuevo. `/v1/usage/runs` junta todas esas llamadas de vuelta en el mensaje que las originó.

```bash
curl -H "Authorization: Bearer $TOKEN" "https://pepe.ejemplo.com/v1/usage/runs?limit=50"
```

```json
{
  "object": "list",
  "data": [
    {
      "id": "1785312000123456",
      "at": 1785312000,
      "project": "acme",
      "agent": "acme/ventas",
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

`source` indica qué disparó la ejecución (`telegram`, `api`, `cron`, `flow`, y así), `outcome` es `ok` o `error`, y `ms` es cuánto tardó el mensaje completo.

Fíjate en lo que dicen juntos `calls: 4` y `tool_calls: 3`. Una herramienta no consume tokens por sí sola; lo que encarece un mensaje es la cantidad de llamadas al modelo, porque cada iteración vuelve a mandar un contexto que el resultado de la herramienta anterior acaba de agrandar. Por eso la unidad que vale la pena mirar es la ejecución completa, no la herramienta suelta.

## Un mensaje, llamada por llamada

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.ejemplo.com/v1/usage/runs/1785312000123456"
```

Devuelve los mismos campos que la fila de la lista, más un `breakdown`: cada llamada al modelo de esa ejecución, en orden, con sus propios tokens, aciertos de caché e importes. Ahí está la respuesta a "¿por qué costó tanto este mensaje?".

Un token creado con `--content` recibe además un objeto `content` con el prompt y los argumentos/salida de cada herramienta. Sin ese flag, la clave `content` directamente no existe. Viene apagado por defecto a propósito: un informe de consumo es una factura, y una factura no es una transcripción. El contenido también proviene del [trace](../traces/) de esa ejecución, que se recorta por proyecto con el tiempo, así que una ejecución suficientemente vieja devuelve `content: null` en vez de simular que nunca tuvo nada.

## Filtros

Cada endpoint acepta los que tienen sentido para él:

| Parámetro | Dónde | Significado |
| --- | --- | --- |
| `project` | todos | un solo proyecto, y solo uno que el token ya alcance |
| `agent` | todos | el gasto de un agente puntual |
| `model` | resumen, eventos | una conexión de modelo |
| `source` | todos | `telegram`, `api`, `cron`, `flow`, … |
| `session` | todos | una conversación |
| `run_id` | resumen, eventos | las llamadas de un mensaje |
| `from` / `to` | todos | segundos unix, `[from, to)` |
| `limit` | todos | tamaño de página (máx. 1000) |
| `cursor` | eventos, ejecuciones | el `next_cursor` de la página anterior |
| `granularity` | resumen | `hour`, `day`, `week`, `month`, `year` |

Un filtro solo puede acotar lo que el token ya alcanza, nunca ampliarlo. Nombrar un proyecto fuera de su alcance devuelve **403**, no un resultado vacío, y un token restringido a un agente se queda en ese agente sin importar lo que diga `agent=`. Usar `model=` o `run_id=` en `/runs` da **400**: una ejecución no tiene un único modelo, y para un id de ejecución puntual está `/runs/:id`; un filtro que en silencio no hace nada devolvería un informe que creerías más acotado de lo que realmente es.

## Errores

| Estado | Cuándo |
| --- | --- |
| 401 | token ausente o desconocido |
| 403 | el token no puede leer el consumo, o pidió un proyecto fuera de su alcance |
| 404 | esa ejecución no existe dentro del alcance del token |
| 400 | algún parámetro inutilizable |

Una ejecución que pertenece a otro proyecto responde **404** en lugar de 403, para que el endpoint nunca confirme que un id existe en algún lugar que no puedes ver.
