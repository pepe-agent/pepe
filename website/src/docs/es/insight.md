---
title: Insight
description: Entrena modelos locales de predicción, agrupamiento, detección de anomalías y pronóstico de tendencias con tus propios datos, para que una pregunta repetida se responda al instante y gratis, en vez de razonarse desde cero cada vez.
---

La herramienta `insight` le permite a un agente convertir datos ya verificados en un
modelo pequeño que él mismo entrena y guarda, para que una pregunta específica y repetida
("¿este paciente va a empeorar?", "¿este lead va a convertir?", "¿cuántos ingresos la
semana que viene?") se conteste al instante, sin ninguna llamada al modelo, en cuanto haya
suficiente historial para aprender. Pepe elige el algoritmo solo, según cuántos datos
existan de verdad; no hay nada que configurar ni ajustar.

Esto no es investigación abierta de machine learning. Es responder una pregunta bien
definida, a partir de datos que ya tienes, una capacidad real y acotada, no descubrimiento
libre.

## Cuatro tipos de pregunta

- **Clasificación**: predecir una categoría. *¿Este paciente va a reingresar en los
  próximos 30 días? ¿Este ticket de soporte va a escalar a un gerente? ¿Esta transacción
  es fraude?*
- **Regresión**: predecir un número. *¿Cuántos días probablemente va a estar internado
  este paciente? ¿Cuánto va a gastar este cliente el próximo mes? ¿Cuántas unidades de
  este producto se van a vender esta semana?*
- **Pronóstico de tendencia**: predecir un número **a lo largo del tiempo**. *¿Cuántos
  ingresos la semana que viene, según la tendencia hasta ahora? ¿Cómo se ve la
  facturación del próximo mes? ¿Cuántos tickets de soporte hay que esperar el lunes por
  la mañana?*
- **Agrupamiento**: juntar filas parecidas entre sí, sin ningún objetivo definido. *¿Qué
  perfiles de paciente hay en estos datos, y cuál paciente no encaja en ninguno de ellos?
  ¿Qué segmentos aparecen en un año entero de pedidos? ¿Qué transacciones no se parecen
  en nada al resto?*

Ninguno de estos tipos es exclusivo de salud: el mismo pipeline de clasificación sirve
para un equipo de soporte que predice si un ticket va a escalar o para una clínica que
predice riesgo de reingreso. Lo que cambia entre los dos es la columna objetivo y las
columnas usadas para predecirla, no el tipo de modelo.

En términos de ML: clasificación, regresión y pronóstico de tendencia son aprendizaje
supervisado, porque el modelo aprende a partir de ejemplos donde la respuesta ya se
conoce. El agrupamiento es el único tipo no supervisado aquí: no hay respuesta conocida
ni ejemplo etiquetado, el modelo encuentra los grupos por su cuenta a partir de los datos.

El agrupamiento resuelve detección de anomalías de regalo: una fila muy alejada del patrón
habitual de su grupo vuelve marcada, con el mismo modelo que hizo el agrupamiento. Un
paciente cuyos signos vitales lo ubican lejos del grupo al que normalmente pertenecería es
justo ese tipo de anomalía, vale la pena revisarlo antes de que se convierta en una
emergencia.

## De dónde vienen los datos

Dos fuentes, elegidas al definir qué predecir:

- **Una conexión de base de datos ya configurada** (las mismas que ya usan
  `db_query`/`manage_db`, Postgres, aislada por tenant mediante Row-Level Security cuando
  está configurado, ve [Base de datos](/es/docs/database/)).
- **Filas importadas**: entrega las filas directamente con `import_rows`. Es el camino
  para cualquier fuente que Pepe no tenga conector nativo: un agente lee un archivo,
  consulta otro motor de base de datos vía `bash` (ve [Base de datos](/es/docs/database/)
  sobre el RLS, que solo aplica a Postgres), o trae datos de una API, y entrega las filas
  resultantes. Las dos fuentes entrenan por el mismo proceso; el algoritmo nunca sabe de
  cuál de las dos vinieron los datos.

## ¿Todavía no sabes qué predecir?

Pide "analiza mis datos en busca de insights" y, para una conexión de base de datos,
`insight propose_targets` toma una muestra de filas reales y sugiere columnas candidatas:
una columna de baja cardinalidad es una categoría plausible para clasificar, una columna
numérica con variación real es algo para predecir por regresión, un nombre como
`status`/`risk`/`churn` suma a favor. Es una heurística, no una garantía, y no define nada
por sí sola - es un punto de partida para confirmar, no una spec terminada.

## Definir qué predecir

No hay una sintaxis aparte que aprender: describe lo que quieres en la conversación, y el
agente completa la llamada real a `insight define`. Para una spec de clasificación o
regresión, indica el objetivo y de qué columnas predecirlo: "predecir si un paciente
reingresa en 30 días, usando edad, días internado e ingresos previos, desde la tabla
`altas` en `pacientes_prod`". Un pronóstico de tendencia indica una columna de tiempo en
vez de (o además de) otras columnas: "pronosticar el total de ingresos por día, sobre la
columna `dia`". Un agrupamiento no indica ningún objetivo, solo qué agrupar: "agrupar
pacientes por edad, cantidad de comorbilidades e ingresos previos".

Después, `insight import_rows` (para una spec importada) o `insight train_now` (para
cualquiera de las dos) en cuanto haya suficiente historial, y `insight_predict` para
obtener una respuesta, ver qué hay definido y el historial de cada modelo. Es una
herramienta aparte a propósito: `insight` (define/import_rows/train_now/delete) es la que
cambia algo; `insight_predict` (predict/list/describe) solo lee. Esa separación permite
que un operador habilite predicciones para una superficie sin humano de por medio (un
cron, un webhook) sin darle también el poder de redefinir o reentrenar lo que está
prediciendo.

## Cómo elige Pepe el algoritmo

Por defecto, nunca es una elección manual: el modelo se elige según cuántos datos
verificados existan de verdad, la misma filosofía de "que lo resuelva solo" detrás del
[enrutamiento por complejidad](/es/docs/routing/):

- **De unos cientos a un par de miles de filas**: regresión simple. Rápida, robusta, sin
  riesgo de memorizar los datos de más. Una clínica con unos cientos de registros de alta
  ya sale con un modelo funcionando al instante.
- **De un par de miles a decenas de miles de filas**: árboles con gradient boosting
  (XGBoost), la base más sólida para este tipo de datos en la escala que tiene la mayoría
  de los operadores.
- **Decenas de miles de filas en adelante**: una red neuronal pequeña (compilada vía EXLA
  cuando está disponible), reservada para quien tiene un historial realmente grande
  (cientos de millones de eventos de paciente, por ejemplo), suficientes datos para que
  esa complejidad valga la pena.

Un pronóstico de tendencia es, por debajo, una regresión, con la fecha convertida
automáticamente en tiempo transcurrido y atributos de día de la semana/mes, se aplican las
mismas tres franjas. Un modelo de esta escala nunca entrena con todas las filas de una
tabla gigante: el entrenamiento usa una muestra aleatoria representativa (`TABLESAMPLE` de
Postgres, no "las primeras N filas", que sesgaría según cómo esté ordenada la tabla),
limitada a 200 mil filas, pasado cierto punto, más filas dejan de mejorar de forma
relevante un modelo de este tamaño.

Un operador que ya sabe qué algoritmo quiere puede indicarlo explícitamente con el
`family` de `define` ("linear", "gbm" o "neural") en vez de dejarlo automático - útil si
ya comparó sus propios datos, o simplemente prefiere el que ya conoce. Déjalo sin definir
salvo que lo pidan; automático es la opción correcta para casi todos.

## Reentrenamiento

Define `retrain_interval_s` en una spec y Pepe la reentrena solo en cuanto lleguen
suficientes filas nuevas (`min_new_rows`, por defecto 50), un modelo de riesgo de paciente
se vuelve más preciso a medida que se registran más altas, sin que nadie tenga que correr
nada a mano. `insight train_now` reentrena al instante, sin importar eso.

## Lo que esto no hace

Cada modelo responde una sola pregunta, definida de antemano, a partir de datos
estructurados con columnas numéricas. No lee texto libre (un resumen de alta, un PDF de
historia clínica), esos datos tienen que convertirse en columnas antes de que Insight
pueda usarlos. No hace series de tiempo más allá de tendencia y estacionalidad
semanal/anual, y no hace imagen ni audio. Si la pregunta necesita criterio en vez de un
patrón en datos pasados, de eso se encarga el propio agente, razonando turno a turno, no
Insight.
