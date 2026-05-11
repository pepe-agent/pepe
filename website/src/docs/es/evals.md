---
title: Evals
description: Reproduce prompts conocidos en un agente y comprueba la respuesta y las herramientas que usó.
---

Un **eval** reproduce un prompt conocido en un agente y hace aserciones sobre la
respuesta y sobre las herramientas que el agente usó. Es tu red de regresión para
el comportamiento: cambias un prompt, un modelo o un conjunto de herramientas,
ejecutas los evals y ves al instante si se rompió algo que te importaba.

Esto importa porque los agentes no son deterministas, así que un test de cadena
exacta es inútil. Un eval comprueba lo que de verdad importa. ¿Llamó a la
herramienta correcta? ¿Mencionó la respuesta? ¿Evitó afirmar que no tiene acceso?

## Tus traces ya son los datos de prueba que tienes

La parte difícil de una suite de evals no es ejecutarla, es *escribirla*, y nadie
encuentra nunca la tarde para hacerlo. Así que no escribas ninguna. Cuando el
agente resuelva algo bien, guarda esa ejecución:

```bash
pepe eval add a1b2c3                                   # un id de trace
pepe eval add a1b2c3 --suite support --contains "refund,5 business days"
```

En el panel es un botón sobre el trace: **✓ Esto salió bien**.

### Qué comprueba el caso en realidad

El caso guarda el prompt y el agente tal cual, y comprueba **las herramientas que
el agente usó**. Esa es la aserción que vale la pena tener. Sobrevive a las
actualizaciones de modelo y a las reformulaciones, y es exactamente lo que cambia
cuando una edición sale mal: el agente deja de consultar las cosas y empieza a
inventarlas, o recurre a la shell donde antes leía un archivo. Un modelo que
responde a la misma pregunta con las mismas herramientas es un modelo que sigue
funcionando como decidiste que debía funcionar.

Deliberadamente **no** exige la misma frase de vuelta. Dos ejecuciones del mismo
prompt nunca producen una frase idéntica, y un test que insiste en eso queda
silenciado en una semana y, a partir de ahí, no protege nada. La respuesta que
estaba bien se guarda en el caso, bajo `recorded`, para quien lea un fallo. Si
algunas palabras de esa respuesta *eran* el punto, dilo con `--contains` y también
se comprueban.

Las ejecuciones fallidas se rechazan. Promover una congelaría el fallo como
expectativa y te entregaría una suite en verde precisamente para él.

## Cómo va esto en la práctica, de principio a fin

Nunca has escrito un eval y no vas a empezar hoy. Bien. Haz esto en su lugar.

**1. Usa Pepe con normalidad.** Habla con tu agente, deja que tus clientes hablen
con él. Cada ejecución ya se está registrando, así que no tienes que hacer nada
para que eso ocurra.

**2. Cuando algo salga bien, dilo.** Abre el panel, ve a [Traces](../traces/),
pulsa en la ejecución y pulsa **✓ Esto salió bien**. Esa es toda la ceremonia.
Desde el terminal es lo mismo:

```bash
pepe traces                       # las ejecuciones recientes, con sus ids
pepe eval add a1b2c3              # guarda esa
# ✓ added to recorded: What is the price of the annual plan?
#   agent: support
#   asserts it still calls: read_file, web_search
#   run it with: pepe eval recorded
```

Hazlo cuatro o cinco veces a lo largo de una semana, siempre que notes que el
agente hace lo correcto. Ya tienes una suite que describe a tu agente, escrita por
tu agente, sobre las cosas que tus clientes preguntan de verdad.

**3. Antes de cambiar nada, ejecútala.**

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

Esa cruz es todo el sentido de la funcionalidad. El agente siguió respondiendo. La
respuesta seguía leyéndose bien. Simplemente dejó de abrir el archivo y empezó a
recitar de memoria y, el mes que viene, cuando cambie el precio, habría seguido
citando con toda confianza el precio antiguo. No se lanzó ninguna excepción, no se
escribió ninguna línea de log y, sin esta suite, te habrías enterado por un
cliente.

**4. Ponla en CI.** Una ejecución que no pasa sale con código distinto de cero, así
que entra directamente junto a tus tests. Ahora una edición de persona que rompe
algo no puede llegar a producción en silencio.

<div class="note"><strong>Cuando un caso está mal, bórralo.</strong> Son archivos JSON bajo <code>~/.pepe/evals/</code>. Un caso que ya no refleja lo que quieres es un caso que hay que quitar, no con el que discutir. La suite es un registro de decisiones, y las decisiones cambian.</div>

## Ejecución

```bash
pepe eval               # ejecuta todas las suites (las incluidas + las tuyas)
pepe eval arithmetic    # ejecuta una suite
pepe eval list          # lista las suites y su número de casos
pepe eval add TRACE_ID  # guarda una ejecución que salió bien (ver arriba)
pepe eval --seed        # copia las suites incluidas en ~/.pepe/evals para editarlas
pepe eval help
```

Cada caso ejecuta un turno real contra un modelo real, así que los evals necesitan
un modelo configurado. Una ejecución imprime una marca o una cruz por caso (con el
motivo, si falla) y un total. Una ejecución que no pasa sale con código distinto de
cero, así que encaja en CI.

## Suites que vienen con Pepe

Estas se ejecutan contra tu **agente por defecto**, ya que los casos omiten
`agent`, es decir, contra aquel al que apunta `pepe agent default`. Las suites de
herramientas dan por hecho que ese agente tiene las herramientas nativas
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

Son **plantillas**: codifican expectativas razonables, no verdad universal. Un
modelo flojo o un agente con otras herramientas fallará algunas, y ese es
precisamente el punto. Ejecuta `pepe eval --seed` para copiarlas en
`~/.pepe/evals` y ajustar los prompts y las aserciones a tus propios agentes.

## Escribir las tuyas

Una suite es un archivo JSON: una lista de casos. Pon las tuyas en
`~/.pepe/evals/<nombre>.json`. Un archivo ahí **eclipsa** a una suite incluida con
el mismo nombre.

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

Todas las claves de `expect` son opcionales, y un caso pasa cuando se cumplen
todas las aserciones presentes:

| Clave | Pasa cuando |
|---|---|
| `contains` | La respuesta incluye cada una de las cadenas (sin distinguir mayúsculas). |
| `not_contains` | La respuesta no incluye ninguna de estas cadenas. |
| `matches` | La respuesta casa con esta expresión regular (usa `(?i)` para ignorar mayúsculas). |
| `tool_called` | Estas herramientas se ejecutaron durante el turno. |
| `tool_not_called` | Estas herramientas no se ejecutaron durante el turno. |

Omite `agent` para ejecutar el caso contra el agente por defecto, o nombra uno
para fijar el caso a él.
