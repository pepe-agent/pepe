---
title: Como ajudar
description: Ajude com issues, revisão de texto, traduções, testes de modelos e pull requests.
---

Pepe é um projeto novo. Ajuda pequena e focada já faz diferença: abrir uma issue
clara, responder dúvidas, revisar textos, testar provedores, melhorar traduções ou
enviar um PR.

## Formas úteis de ajudar

- **Abrir issues boas.** Diga o que tentou, o que esperava, o que aconteceu e
  cole logs ou comandos relevantes.
- **Responder issues.** Reproduza bugs, peça detalhes que faltam, confirme se uma
  solução funciona.
- **Melhorar textos.** Corte explicações longas, troque traduções literais por
  frases naturais e ajuste exemplos que soam artificiais.
- **Traduzir.** Mantenha inglês, espanhol, pt-BR e pt-PT alinhados. Traduza texto
  de leitor; preserve comandos, nomes de ferramentas, payloads e APIs.
- **Testar modelos.** Confirme streaming e tool calling em OpenAI, OpenRouter,
  Groq, DeepSeek, Together, Mistral, Ollama, LM Studio, vLLM e outros provedores.
- **Enviar PRs pequenos.** Um bug, uma página, uma tradução ou uma melhoria por
  PR é mais fácil de revisar.

## Do fork ao PR

1. Faça um fork no GitHub.
2. Clone seu fork:

```bash
git clone git@github.com:SEU_USUARIO/pepe.git
cd pepe
```

3. Adicione o repositório original como upstream:

```bash
git remote add upstream https://github.com/pepe-agent/pepe.git
git fetch upstream
```

4. Crie uma branch a partir da principal:

```bash
git checkout -b docs-melhora-quickstart upstream/master
```

5. Instale dependências e rode os testes:

```bash
mix deps.get
mix test
```

6. Se for mexer no website:

```bash
cd website
npm install
npm run dev
```

7. Faça a mudança. Para docs e textos, revise também os outros idiomas quando a
mesma página existir neles.

8. Rode a checagem final na raiz do projeto:

```bash
mix precommit
```

9. Faça commit e envie para o seu fork:

```bash
git add .
git commit -m "Improve quickstart copy"
git push origin docs-melhora-quickstart
```

10. Abra um pull request contra `pepe-agent/pepe:master`. Explique o que mudou, por
que mudou e linke a issue, se houver.

## Bons PRs

Um bom PR é pequeno, tem escopo claro e deixa fácil entender a decisão. Para código,
inclua teste quando mudar comportamento. Para documentação, prefira frases curtas,
exemplos reais e links para páginas mais detalhadas em vez de repetir tudo.

## Ajuda com modelos

Relatos de provedores são muito úteis. O relatório ideal inclui:

- provedor e modelo testado;
- comando usado para configurar;
- resultado de `pepe model test`;
- um prompt simples que respondeu em streaming;
- um prompt que exigiu ferramenta, como ler arquivo ou buscar na web.

Se algo falhar, abra uma issue com esse contexto. Mesmo um “testei e funcionou”
ajuda a saber quais integrações estão saudáveis.

