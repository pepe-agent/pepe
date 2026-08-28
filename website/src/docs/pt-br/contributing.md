---
title: Como ajudar
description: Ajude com issues, revisão de texto, traduções, testes de modelos e pull requests.
---

O Pepe ainda é um projeto novo, e uma ajuda pequena e bem direcionada já faz diferença:
abrir uma issue clara, responder dúvidas, revisar textos, testar provedores, melhorar
traduções ou mandar um PR.

## Formas úteis de contribuir

- **Abra issues boas.** Conte o que você tentou, o que esperava que acontecesse e o que
  de fato aconteceu, e cole os comandos ou logs relevantes.
- **Responda issues.** Tente reproduzir o bug, peça os detalhes que faltarem e confirme
  se uma correção resolveu.
- **Melhore os textos.** Corte explicações longas demais, troque traduções literais por
  frases que soem naturais e ajuste exemplos artificiais.
- **Traduza.** Mantenha inglês, espanhol, pt-BR e pt-PT alinhados entre si. Traduza o
  texto pensado para o leitor; comandos, nomes de ferramentas, payloads e APIs ficam
  como estão.
- **Teste modelos.** Confirme que streaming e tool calling funcionam em OpenAI,
  OpenRouter, Groq, DeepSeek, Together, Mistral, Ollama, LM Studio, vLLM e outros
  provedores.
- **Mande PRs pequenos.** Um bug, uma página, uma tradução ou uma melhoria por PR é
  muito mais fácil de revisar do que várias coisas juntas.

## Do fork ao PR

1. Faça um fork do repositório no GitHub.
2. Clone o seu fork:

```bash
git clone git@github.com:SEU_USUARIO/pepe.git
cd pepe
```

3. Adicione o repositório original como upstream:

```bash
git remote add upstream https://github.com/pepe-agent/pepe.git
git fetch upstream
```

4. Crie uma branch a partir da master:

```bash
git checkout -b docs-melhora-quickstart upstream/master
```

5. Instale as dependências e rode os testes:

```bash
mix deps.get
mix test
```

6. Se a mudança for no website:

```bash
cd website
npm install
npm run dev
```

7. Faça a alteração. Em docs e textos, olhe também os outros idiomas quando a mesma
página existir neles.

8. Rode a checagem final a partir da raiz do projeto:

```bash
mix precommit
```

9. Faça o commit e envie para o seu fork:

```bash
git add .
git commit -m "Improve quickstart copy"
git push origin docs-melhora-quickstart
```

10. Abra um pull request contra `pepe-agent/pepe:master`, explicando o que mudou e por
quê, e linkando a issue relacionada, se houver uma.

## O que faz um bom PR

Um PR pequeno, com escopo bem definido, é sempre mais fácil de revisar. Para código,
inclua um teste sempre que o comportamento mudar. Para documentação, prefira frases
curtas, exemplos reais, e um link para a página que aprofunda o assunto em vez de
repetir tudo de novo.

## Ajudando com modelos

Relatos sobre provedores são particularmente úteis. Um bom relatório costuma trazer:

- provedor e modelo testados;
- o comando usado para configurar;
- a saída de `pepe model test`;
- um prompt simples que respondeu em streaming;
- um prompt que precisou de alguma ferramenta, como ler um arquivo ou buscar na web.

Se algo falhar, abra uma issue com esse contexto. Até um relato de "testei e funcionou"
ajuda a mapear quais integrações estão saudáveis.
