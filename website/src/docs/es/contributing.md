---
title: Cómo ayudar
description: Ayuda con issues, revisión de texto, traducciones, pruebas de modelos y pull requests.
---

Pepe es un proyecto joven. La ayuda pequeña y enfocada ya cuenta: abrir una issue
clara, responder dudas, revisar textos, probar proveedores, mejorar traducciones o
enviar un PR.

## Formas útiles de ayudar

- **Abrir buenas issues.** Cuenta qué probaste, qué esperabas, qué ocurrió e
  incluye comandos o logs relevantes.
- **Responder issues.** Reproduce bugs, pide detalles que falten y confirma si una
  solución funciona.
- **Mejorar textos.** Recorta explicaciones largas, cambia traducciones literales
  por frases naturales y ajusta ejemplos que suenen artificiales.
- **Traducir.** Mantén alineados inglés, español, pt-BR y pt-PT. Traduce el texto
  para lectores; conserva comandos, nombres de herramientas, payloads y APIs.
- **Probar modelos.** Confirma streaming y tool calling en OpenAI, OpenRouter,
  Groq, DeepSeek, Together, Mistral, Ollama, LM Studio, vLLM y otros proveedores.
- **Enviar PRs pequeños.** Un bug, una página, una traducción o una mejora por PR
  es más fácil de revisar.

## Del fork al PR

1. Haz un fork en GitHub.
2. Clona tu fork:

```bash
git clone git@github.com:TU_USUARIO/pepe.git
cd pepe
```

3. Añade el repositorio original como upstream:

```bash
git remote add upstream https://github.com/pepe-agent/pepe.git
git fetch upstream
```

4. Crea una rama desde master:

```bash
git checkout -b docs-mejora-quickstart upstream/master
```

5. Instala dependencias y ejecuta las pruebas:

```bash
mix deps.get
mix test
```

6. Si vas a cambiar el website:

```bash
cd website
npm install
npm run dev
```

7. Haz el cambio. Para docs y textos, revisa también los otros idiomas cuando la
misma página exista en ellos.

8. Ejecuta la verificación final desde la raíz:

```bash
mix precommit
```

9. Haz commit y sube la rama a tu fork:

```bash
git add .
git commit -m "Improve quickstart copy"
git push origin docs-mejora-quickstart
```

10. Abre un pull request contra `pepe-agent/pepe:master`. Explica qué cambió, por
qué cambió y enlaza la issue si existe.

## Buenos PRs

Un buen PR es pequeño, tiene alcance claro y facilita la revisión. Para código,
incluye una prueba cuando cambie comportamiento. Para documentación, prefiere
frases cortas, ejemplos reales y enlaces a páginas más profundas antes que repetir
todo.

## Ayuda con modelos

Los informes de proveedores son muy útiles. El informe ideal incluye:

- proveedor y modelo probado;
- comando usado para configurarlo;
- salida de `pepe model test`;
- un prompt simple que respondió en streaming;
- un prompt que requirió una herramienta, como leer un archivo o buscar en la web.

Si algo falla, abre una issue con ese contexto. Incluso un “probado y funciona”
ayuda a saber qué integraciones están sanas.

