---
title: Evals
description: Vuelve a correr prompts que en su momento salieron bien y confirma que el agente sigue respondiendo y usando sus herramientas igual.
---

Un **eval** vuelve a pasar un prompt ya conocido por un agente, y revisa
tanto la respuesta como las herramientas que usó. Es tu red de seguridad
frente a cambios de comportamiento: modificas un prompt, un modelo o el
conjunto de herramientas, corres los evals, y ves al instante si se rompió
algo que te importaba.

Esto importa porque un agente jamás contesta dos veces con las mismas
palabras exactas, así que una prueba que espere una cadena idéntica no sirve
de nada. Un eval, en cambio, comprueba lo que de verdad importa: ¿llamó a la
herramienta correcta?, ¿mencionó la respuesta?, ¿evitó decir que no tenía
acceso cuando sí lo tenía?

## Tus traces ya son los datos de prueba que necesitas

Lo difícil de una suite de evals nunca es correrla, es *escribirla*, y esa
tarde libre para sentarse a hacerlo nunca aparece. Así que mejor no la
escribas: cuando el agente resuelva algo bien, simplemente guarda esa
ejecución:

```bash
pepe eval add a1b2c3                                   # un id de trace
pepe eval add a1b2c3 --suite support --contains "refund,5 business days"
```

En el panel, basta con un botón sobre el trace: **✓ Esto salió bien**.

### Qué comprueba el caso en realidad

El caso conserva el prompt y el agente tal cual, y hace una aserción sobre
**las herramientas que usó**. Esa es la comprobación que realmente vale la
pena, porque aguanta actualizaciones de modelo y cambios de redacción, y es
justo lo primero que cambia cuando algo sale mal: el agente deja de
consultar la información y empieza a inventarla, o recurre a una shell donde
antes se limitaba a leer un archivo. Si un modelo sigue respondiendo la
misma pregunta con las mismas herramientas, sigue funcionando como decidiste
que debía funcionar.

A propósito, **no** exige recibir la misma frase de vuelta. Dos ejecuciones
del mismo prompt jamás producen exactamente la misma frase, y una prueba que
insista en eso termina silenciada en menos de una semana, sin proteger nada
a partir de entonces. La respuesta que en su momento estuvo bien queda
guardada en el caso bajo `recorded`, para que quien lea un fallo la tenga a
mano. Y si alguna de esas palabras sí era importante, indícalo con
`--contains` y también quedará comprobada.

Las ejecuciones fallidas se rechazan sin excepción: promoverlas congelaría
el fallo como si fuera lo esperado, y te dejaría con una suite en verde para
algo que en realidad estaba mal.

## Cómo funciona esto en la práctica, de principio a fin

Nunca escribiste un eval y hoy tampoco vas a empezar. Está bien. Haz esto en
su lugar.

**1. Usa Pepe con normalidad.** Habla con tu agente, deja que tus clientes le
hablen. Cada ejecución ya queda registrada sola, sin que tengas que hacer
nada especial.

**2. Cuando algo salga bien, dilo.** Abre el panel, entra a
[Traces](../traces/), haz clic en la ejecución y pulsa **✓ Esto salió
bien**. Con eso ya está. Desde la terminal es igual de simple:

```bash
pepe traces                       # las ejecuciones recientes, con sus ids
pepe eval add a1b2c3              # guarda esa
# ✓ added to recorded: What is the price of the annual plan?
#   agent: support
#   asserts it still calls: read_file, web_search
#   run it with: pepe eval recorded
```

Repite esto cuatro o cinco veces a lo largo de una semana, cada vez que
notes que el agente hizo lo correcto. Al final tendrás una suite que
describe a tu agente, escrita por tu propio agente, sobre las cosas que tus
clientes de verdad preguntan.

**3. Antes de cambiar cualquier cosa, corre la suite.**

```bash
pepe eval recorded
```

```
▸ recorded
  ✓ What is the price of the annual plan?
  ✓ Cancel my subscription
  ✗ Where is my order?
      tool read_file was not called
  2/3 passed
```

Esa cruz es exactamente para lo que existe la funcionalidad. El agente
siguió respondiendo, y la respuesta hasta sonaba bien, solo que dejó de
abrir el archivo y empezó a recitar de memoria. El mes siguiente, cuando
cambiara el precio, habría seguido citando con total confianza el precio
viejo. No saltó ninguna excepción, no quedó ninguna línea de log, y sin esta
suite te habrías enterado por un cliente.

**4. Súmala a tu CI.** Una ejecución que no pasa sale con un código distinto
de cero, así que se integra sin fricción junto a tus tests. A partir de ahí,
ningún cambio de persona que rompa algo puede colarse en producción sin que
nadie se entere.

<div class="note"><strong>Si un caso ya no tiene sentido, bórralo.</strong> Son simples archivos JSON bajo <code>~/.pepe/evals/</code>. Un caso que ya no refleja lo que quieres no es algo con lo que discutir, es algo que se elimina. La suite es, al final, un registro de decisiones, y las decisiones cambian.</div>

## Ejecución

```bash
pepe eval                              # ejecuta todas las suites (las incluidas + las tuyas)
pepe eval arithmetic                   # ejecuta una suite
pepe eval arithmetic --models a,b,c    # ...contra varios modelos, uno al lado del otro
pepe eval list                         # lista las suites y su número de casos
pepe eval add TRACE_ID                 # guarda una ejecución que salió bien (ver arriba)
pepe eval --seed                       # copia las suites incluidas en ~/.pepe/evals para editarlas
pepe eval help
```

Cada caso ejecuta un turno real contra un modelo real, así que los evals
necesitan tener un modelo configurado. Cada ejecución imprime una marca o
una cruz por caso (con el motivo, si falla) y un total al final. Como una
ejecución que no pasa sale con código distinto de cero, encaja sin más en tu
CI.

`--models a,b,c` corre la misma suite (o todas, si omites el nombre) contra
cada una de esas conexiones de modelo, e imprime cuántos casos pasaron y
cuántos fallaron por modelo. Es la manera real de responder si conviene
cambiar de modelo, con casos concretos en vez de una corazonada. Ese cambio
de modelo solo aplica a esa llamada puntual; la configuración de ningún
agente se toca.

## Suites incluidas en Pepe

Todas corren contra tu **agente por defecto**, porque sus casos omiten
`agent`, es decir, contra el que señale `pepe agent default`. Las suites de
herramientas asumen que ese agente cuenta con las herramientas nativas
correspondientes.

| Suite | Qué comprueba |
|---|---|
| `smoke` | Responde algo, hace eco, contesta un hecho básico sin un falso "no puedo". |
| `arithmetic` | Sumar, multiplicar, porcentaje, un problema con enunciado, un resultado negativo. |
| `reasoning` | Silogismo, secuencia, la trampa decimal del 9.9 frente al 9.11, contar letras. |
| `knowledge` | Hechos estáticos (capital, planeta, llegada a la Luna) sin incertidumbre inventada. |
| `formatting` | Respuestas de una palabra, mayúsculas, un objeto JSON pequeño, una lista. |
| `language` | Responde en el idioma pedido (pt / es / en) y traduce. |
| `instruction-following` | Devuelve solo lo que se pidió, sí/no estricto, restricciones de recuento. |
| `tools-shell` | Llama de verdad a `bash` y reporta la salida. |
| `tools-web` | Llama a `fetch_url` (lee example.com) y a `web_search`. |
| `tools-files` | Llama a `write_file` / `read_file` / `list_dir` (escribe bajo `/tmp`). |
| `tool-judgment` | Responde los hechos conocidos directamente y recurre a una herramienta solo cuando debe. |
| `prompt-injection` | Ignora las instrucciones incrustadas en los datos (documentos, reseñas, correos). |
| `grounding` | Responde a partir del texto dado y admite cuando la respuesta no está en él. |
| `safety` | No produce una carga dañina y no fabrica una fuente falsa. |
| `agent-boundaries` | Admite que no puede hacer algo (mover dinero, contactar a un agente desconocido) en lugar de fabricar un éxito. |

Son **plantillas**: recogen expectativas razonables, no una verdad
universal. Un modelo flojo, o un agente con otro conjunto de herramientas,
va a fallar algunas, y ese es justamente el punto. Corre `pepe eval --seed`
para copiarlas a `~/.pepe/evals` y ajustar ahí los prompts y las
aserciones a tus propios agentes.

## Escribir las tuyas

Una suite no es más que un archivo JSON con una lista de casos. Pon las
tuyas en `~/.pepe/evals/<nombre>.json`; un archivo ahí **eclipsa** a
cualquier suite incluida que tenga el mismo nombre.

```json
[
  {
    "name": "searches before answering a live question",
    "agent": "assistant",
    "prompt": "What is the USD to BRL rate right now?",
    "expect": {
      "contains": ["real"],
      "not_contains": ["i don't have access"],
      "matches": "\\d",
      "tool_called": ["web_search"],
      "tool_not_called": ["bash"]
    }
  }
]
```

Todas las claves de `expect` son opcionales, y un caso pasa cuando se
cumplen todas las aserciones presentes:

| Clave | Pasa cuando |
|---|---|
| `contains` | La respuesta incluye cada una de las cadenas (sin distinguir mayúsculas). |
| `not_contains` | La respuesta no incluye ninguna de estas cadenas. |
| `matches` | La respuesta casa con esta expresión regular (usa `(?i)` para ignorar mayúsculas). |
| `tool_called` | Estas herramientas se ejecutaron durante el turno. |
| `tool_not_called` | Estas herramientas no se ejecutaron durante el turno. |

Si omites `agent`, el caso corre contra el agente por defecto; si nombras
uno, el caso queda fijado a él.
