---
title: Objetivos
description: Ejecuta un agente hacia un resultado, verificado por un revisor independiente, hasta que esté realmente hecho.
---

## Dar un prompt vs. perseguir un objetivo

Un prompt te compra **un turno**. El agente responde y luego *tú* decides si está bien, pides un ajuste y repites. Eso te mete dentro del bucle como aprobador e inspector de calidad a la vez, y el trabajo solo avanza mientras estás frente al teclado.

Un **objetivo** te compra un **resultado**. Dices qué significa "terminado", y Pepe sigue trabajando hasta que un revisor independiente confirme que se llegó, o hasta que se agoten los intentos.

La diferencia está en **quién verifica**. En un turno normal es el propio agente quien decide que terminó, que es justamente la evaluación en la que no puedes confiar. En un objetivo, una **llamada separada al modelo** califica el resultado frente a tu criterio.

## Ejecutar uno

```bash
pepe goal "OBJETIVO" --criteria "cómo sabemos que está hecho" \
  [--max-attempts 3] [--judge MODELO] [--agent NOMBRE]
```

Un ejemplo real:

```bash
pepe goal "limpiar la lista de clientes en ~/datos/clientes.csv" \
  --criteria "sin correos duplicados, y cada fila con un teléfono válido" \
  --max-attempts 4
```

Pepe va imprimiendo cada intento y el veredicto del revisor:

```
── attempt 1/4 ──
[-> read_file clientes.csv]
[✓ read_file]
...
↻ reviewer: 3 filas siguen con la columna de teléfono vacía

── attempt 2/4 ──
...
✅ reviewer: ya no hay correos duplicados y todas las filas tienen teléfono

✅ Goal met after 2 attempt(s).
```

En el panel, lánzalo desde cualquier chat:

```
/goal limpiar la lista de clientes | sin correos duplicados, cada fila con un teléfono válido
```

El panel sobre la conversación muestra entonces el criterio, el número de intento y el último veredicto del revisor mientras trabaja.

## Cómo se mantiene independiente el revisor

El revisor es una llamada nueva, con **contexto limpio**. Nunca ve la conversación de trabajo, solo dos cosas: tu criterio y el resultado final. Así califica el artefacto, no el razonamiento que lo produjo, y no puede ser convencido de aprobar por un agente que está seguro y equivocado.

Por defecto el revisor usa la conexión de modelo del propio agente. Pasa `--judge` para darle un modelo **distinto**, que es la configuración más fuerte: un revisor independiente es más independiente cuando no es el mismo modelo corrigiendo su propio examen.

```bash
pepe goal "..." --criteria "..." --judge gpt-5-review
```

Si la respuesta del revisor llega ilegible, Pepe la cuenta como **no cumplida**. Dejar pasar un veredicto ilegible liberaría un mal resultado, que es justo lo que este bucle existe para evitar.

## El límite de intentos

El límite es **obligatorio** (3 por defecto, 10 como máximo). Un criterio que el agente nunca podrá satisfacer debe costar un número acotado de intentos, no correr para siempre. Al alcanzar el límite, Pepe se detiene, marca el objetivo como `blocked` y te dice qué faltaba:

```
🛑 Gave up at the attempt cap. Still missing: 3 filas siguen con la columna de teléfono vacía
```

Ese mensaje ya vale por sí solo: normalmente es o un criterio imposible, o un obstáculo real que merece tu atención.

## Escribir un criterio que funcione

El criterio es la funcionalidad entera. Uno vago convierte al revisor en un cara o cruz, y el bucle nunca converge.

- **Bueno:** "sin correos duplicados, y cada fila con un teléfono con formato `+NN NNN NNN NNN`"
- **Malo:** "la lista está limpia"

Pregúntate: *un desconocido, viendo solo mi criterio y el resultado, ¿podría decidir sí o no sin preguntarme nada?* Si no, el revisor tampoco puede. Prefiere criterios que nombren una propiedad verificable (un conteo, un formato, un archivo que debe existir, una prueba que debe pasar) antes que criterios que describen una sensación de calidad.

## Objetivos y herramientas

Un objetivo no es un modo especial: envuelve un turno normal. El agente conserva todas sus herramientas, así que puede leer archivos, consultar una base de datos o llamar a una API mientras trabaja hacia el objetivo. Solo la **respuesta final** de cada intento va al revisor.

## Lo que el bucle de objetivo no es

- **No** es un planificador. Para ejecutar algo de forma recurrente, mira [Tareas programadas](/es/docs/scheduled/).
- **No** es un vigía. Para que te avise cuando una condición se cumpla, mira [Watches](/es/docs/watches/).

Un objetivo termina. O llega, o se rinde, y ya está.
