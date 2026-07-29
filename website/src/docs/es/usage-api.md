---
title: API de consumo
description: Lee por HTTP lo que se ha gastado, con un token con alcance, por mensaje, por llamada al modelo, con o sin tu markup.
---

El mismo token que ejecuta un agente también puede crearse para hacer lo contrario: no ejecutar nada y solo leer lo que se ha gastado. Para eso está `/v1/usage`. Responde a la pregunta que una integración de facturación hace de verdad, que no es "cuánto costó este mes", sino "cuánto costó *ese mensaje*, y por qué".

Cuatro endpoints, cuatro niveles de detalle sobre el mismo ledger:

| Endpoint | Una fila por |
| --- | --- |
| `GET /v1/usage` | intervalo de tiempo (hora, día, semana, mes, año) |
| `GET /v1/usage/events` | llamada al modelo |
| `GET /v1/usage/runs` | mensaje entrante |
| `GET /v1/usage/runs/:id` | ese mensaje, llamada a llamada |

Usan la misma cabecera `Authorization: Bearer pepe_...` que el resto de la [API HTTP](../api/) y solo responden sobre los proyectos que el token alcanza. Consulta [Facturación y límites](../billing/) para ver cómo se calculan las cifras.

## Un token que solo lee

Un token puede ejecutar agentes y **no** puede leer el consumo salvo que lo indiques, así que nada de lo que ya has creado cambia. Crea un token de facturación de solo lectura así:

```bash
pepe token add --project acme --no-chat --usage --prices billable --label "facturación acme"
```

Ese token llama a `/v1/usage`, no llama a `/v1/chat/completions`, ve solo el proyecto `acme` y ve solo lo que paga el cliente. Entrégalo al sistema financiero del cliente sin darle además una credencial capaz de gastar tu presupuesto de modelo.

Los cuatro permisos:

| Flag | Por defecto | Qué concede |
| --- | --- | --- |
| `--chat` / `--no-chat` | activado | ejecutar agentes (`/v1/chat/completions`, el WebSocket) |
| `--usage` | desactivado | leer `/v1/usage` |
| `--prices` | `billable` | cuánto de los importes muestra una lectura |
| `--content` | desactivado | el detalle de una ejecución puede incluir el prompt y los argumentos y la salida de las herramientas |

Cámbialos después sin rotar el secreto, para que la integración del cliente siga funcionando mientras cambia lo que puede ver:

```bash
pepe token permissions abc123 --prices list
pepe token permissions abc123 --no-usage
```

Los mismos campos están en las tarjetas de token del panel, en **Tokens**, y un agente de confianza con la herramienta `manage_token` puede crear uno desde la conversación. Un token de **widget** nunca puede leer el consumo: vive en el código fuente público de la página.

## Cuánto ve de los importes

Cada llamada medida tiene tres cifras, y `--prices` elige cuál de ellas devuelve una lectura:

* **`billable`**: precio de tarifa × el markup del proyecto. Lo que paga el cliente. El valor por defecto, y el único que debería tener el token de un cliente.
* **`list`**: los mismos tokens al precio del modelo, sin markup aplicado.
* **`all`**: ambos, más `cost` (lo que pagaste de verdad) y `margin`. Tu propia vista.

`billable` y `list` son excluyentes, no acumulativos. Mostrar los dos entrega la razón entre ellos, que es el markup, que es el margen. Un token con `list` ve precios de tarifa *en lugar de*, no además.

Esto lo decide el token, nunca la petición. Un cliente que llama a `?prices=all` recibe la vista de su propio token, no la que pidió.

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

`granularity` es `hour`, `day`, `week`, `month` o `year`, y `limit` limita cuántos intervalos vuelven (60 por defecto).

Un agregado tiene que leer cada entrada de la ventana para sumarla, así que, sin `from`, este endpoint asume los **últimos 90 días** en lugar de todo el historial. La ventana usada vuelve en `period`, para que un informe nunca cubra menos de lo que crees, en silencio. Pide más cuando lo necesites: `from=0` es todo. Un token `all` recibe además `subscriptions` y `margin` en el nivel superior, y un `markup` en cada entrada de `by_project`.

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

Devuelve `next_cursor` como `cursor` para pedir la página siguiente. La paginación usa un id opaco de fila en lugar del timestamp, porque `at` tiene granularidad de un segundo y un salto de página que caiga dentro de un segundo con mucha actividad perdería filas o las repetiría.

## Una fila por mensaje

Es el endpoint que quiere la mayoría de las integraciones. Un solo mensaje entrante suele costar varias llamadas al modelo: el agente responde, llama a una herramienta, recibe el resultado, llama a otra y responde de nuevo. `/v1/usage/runs` reagrupa esas llamadas en el mensaje que las provocó.

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

`source` es lo que disparó la ejecución (`telegram`, `api`, `cron`, `flow`, etc.), `outcome` es `ok` o `error`, y `ms` es lo que tardó el mensaje completo.

Fíjate en lo que dicen juntos `calls: 4` y `tool_calls: 3`. Una herramienta no cuesta tokens por sí misma; lo que encarece un mensaje es el número de llamadas al modelo, porque cada iteración reenvía un contexto que el resultado de la herramienta anterior acaba de agrandar. Por eso la ejecución, y no la herramienta, es la unidad que vale la pena leer.

## Un mensaje, llamada a llamada

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.ejemplo.com/v1/usage/runs/1785312000123456"
```

Devuelve los mismos campos que la fila de la lista, más `breakdown`: cada llamada al modelo de esa ejecución, en orden, con sus propios tokens, aciertos de caché e importes. Es la respuesta a "por qué costó tanto este mensaje".

Un token creado con `--content` recibe además un objeto `content` con el prompt y los argumentos y la salida de cada herramienta. Sin él no existe siquiera la clave `content`. Desactivado por defecto a propósito: un informe de consumo es una factura, y una factura no es una transcripción. El contenido viene también del [trace](../traces/) de la ejecución, que se recorta por proyecto, así que una ejecución lo bastante antigua devuelve `content: null` en lugar de fingir que nunca lo tuvo.

## Filtros

Cada endpoint acepta los que tienen sentido para él:

| Parámetro | Dónde | Significado |
| --- | --- | --- |
| `project` | todos | un proyecto, y solo uno que el token ya alcanza |
| `agent` | todos | el gasto de un agente |
| `model` | resumen, eventos | una conexión de modelo |
| `source` | todos | `telegram`, `api`, `cron`, `flow`, … |
| `session` | todos | una conversación |
| `run_id` | resumen, eventos | las llamadas de un mensaje |
| `from` / `to` | todos | segundos unix, `[from, to)` |
| `limit` | todos | tamaño de página (máx. 1000) |
| `cursor` | eventos, ejecuciones | el `next_cursor` de la página anterior |
| `granularity` | resumen | `hour`, `day`, `week`, `month`, `year` |

Un filtro solo puede estrechar lo que el token ya alcanza. Nombrar un proyecto fuera de su alcance es **403**, no un resultado vacío, y un token fijado a un agente sigue en ese agente, diga lo que diga `agent=`. `model=` y `run_id=` en `/runs` son **400**: una ejecución no tiene un único modelo, un id de ejecución es para `/runs/:id`, y un filtro que en silencio no hace nada devuelve un informe que creerías más estrecho de lo que es.

## Errores

| Estado | Cuándo |
| --- | --- |
| 401 | token ausente o desconocido |
| 403 | el token no puede leer el consumo, o pidió un proyecto que no alcanza |
| 404 | no existe esa ejecución dentro del alcance del token |
| 400 | un parámetro inservible |

Una ejecución de otro proyecto responde **404** en lugar de 403, para que el endpoint nunca confirme que un id existe en algún sitio que no puedes ver.
