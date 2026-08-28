---
title: Cómo ayudar
description: Ayuda con issues, revisión de textos, traducciones, pruebas de modelos y pull requests.
---

Pepe todavía es un proyecto joven, así que hasta una ayuda pequeña y puntual ya
suma: abrir una issue clara, contestar dudas, revisar textos, probar un proveedor,
afinar una traducción o mandar un PR.

## Formas útiles de ayudar

- **Abre buenas issues.** Cuenta qué probaste, qué esperabas que pasara, qué pasó
  en realidad, y agrega los comandos o logs que hagan falta para entenderlo.
- **Responde issues ajenas.** Reproduce el bug, pregunta por los datos que falten
  y confirma si una solución propuesta realmente funciona.
- **Pule los textos.** Acorta explicaciones que se alargan de más, cambia una
  traducción calcada por una frase que suene natural, y arregla ejemplos que se
  sientan forzados.
- **Traduce.** El objetivo es mantener inglés, español, pt-BR y pt-PT al día entre
  sí. Traduce lo que lee una persona; deja intactos comandos, nombres de
  herramientas, payloads y APIs.
- **Prueba modelos.** Confirma que streaming y tool calling funcionen en OpenAI,
  OpenRouter, Groq, DeepSeek, Together, Mistral, Ollama, LM Studio, vLLM y demás
  proveedores.
- **Manda PRs chicos.** Un bug, una página, una traducción o una mejora por PR se
  revisa mucho más rápido que uno que junta varias cosas.

## Del fork al PR

1. Haz un fork del repositorio en GitHub.
2. Clona tu fork:

```bash
git clone git@github.com:TU_USUARIO/pepe.git
cd pepe
```

3. Agrega el repositorio original como upstream:

```bash
git remote add upstream https://github.com/pepe-agent/pepe.git
git fetch upstream
```

4. Crea una rama a partir de master:

```bash
git checkout -b docs-mejora-quickstart upstream/master
```

5. Instala las dependencias y corre las pruebas:

```bash
mix deps.get
mix test
```

6. Si vas a tocar el sitio web:

```bash
cd website
npm install
npm run dev
```

7. Haz el cambio. Si es documentación o texto, revisa también las otras páginas
del mismo idioma y, cuando la página exista en más de un idioma, échales un
vistazo también.

8. Antes de subir nada, corre la verificación final desde la raíz del proyecto:

```bash
mix precommit
```

9. Haz commit y sube la rama a tu fork:

```bash
git add .
git commit -m "Improve quickstart copy"
git push origin docs-mejora-quickstart
```

10. Abre un pull request contra `pepe-agent/pepe:master`, explicando qué cambiaste
y por qué, con un enlace a la issue correspondiente si la hay.

## Qué hace bueno a un PR

Uno pequeño, con un alcance claro, es el que se revisa más rápido. Si tocas
código, suma una prueba cuando el comportamiento cambie. Si es documentación,
prefiere frases cortas, ejemplos reales, y enlazar a la página que profundiza en
vez de repetir todo ahí mismo.

## Ayuda probando modelos

Los reportes sobre proveedores valen oro. Uno ideal trae:

- el proveedor y el modelo que probaste;
- el comando que usaste para configurarlo;
- la salida de `pepe model test`;
- un prompt simple que haya respondido en streaming;
- un prompt que haya necesitado una herramienta, como leer un archivo o buscar en
  la web.

Si algo falla, abre una issue con ese mismo contexto. Incluso un simple "lo probé
y funciona" ayuda a saber qué integraciones están sanas y cuáles no.
