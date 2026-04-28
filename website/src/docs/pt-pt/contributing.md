---
title: Como ajudar
description: Ajuda com issues, revisão de texto, traduções, testes de modelos e pull requests.
---

O Pepe é um projeto novo. Ajuda pequena e focada já faz diferença: abrir uma issue
clara, responder a dúvidas, rever textos, testar fornecedores, melhorar traduções
ou enviar um PR.

## Formas úteis de ajudar

- **Abrir boas issues.** Diz o que tentaste, o que esperavas, o que aconteceu e
  inclui comandos ou logs relevantes.
- **Responder a issues.** Reproduz bugs, pede detalhes em falta e confirma se uma
  correção funciona.
- **Melhorar textos.** Corta explicações longas, troca traduções literais por
  frases naturais e ajusta exemplos artificiais.
- **Traduzir.** Mantém inglês, espanhol, pt-BR e pt-PT alinhados. Traduz texto
  para leitores; preserva comandos, nomes de ferramentas, payloads e APIs.
- **Testar modelos.** Confirma streaming e tool calling em OpenAI, OpenRouter,
  Groq, DeepSeek, Together, Mistral, Ollama, LM Studio, vLLM e outros fornecedores.
- **Enviar PRs pequenos.** Um bug, uma página, uma tradução ou uma melhoria por PR
  é mais fácil de rever.

## Do fork ao PR

1. Faz um fork no GitHub.
2. Clona o teu fork:

```bash
git clone git@github.com:TEU_UTILIZADOR/pepe.git
cd pepe
```

3. Adiciona o repositório original como upstream:

```bash
git remote add upstream https://github.com/pepe-agent/pepe.git
git fetch upstream
```

4. Cria uma branch a partir de master:

```bash
git checkout -b docs-melhora-quickstart upstream/master
```

5. Instala dependências e corre os testes:

```bash
mix deps.get
mix test
```

6. Se fores alterar o website:

```bash
cd website
npm install
npm run dev
```

7. Faz a alteração. Para docs e textos, revê também os outros idiomas quando a
mesma página existir neles.

8. Corre a verificação final na raiz do projeto:

```bash
mix precommit
```

9. Faz commit e envia para o teu fork:

```bash
git add .
git commit -m "Improve quickstart copy"
git push origin docs-melhora-quickstart
```

10. Abre um pull request contra `pepe-agent/pepe:master`. Explica o que mudou, por
que mudou e liga a issue, se houver.

## Bons PRs

Um bom PR é pequeno, tem âmbito claro e facilita a revisão. Para código, inclui
um teste quando muda comportamento. Para documentação, prefere frases curtas,
exemplos reais e links para páginas mais detalhadas em vez de repetir tudo.

## Ajuda com modelos

Relatórios de fornecedores são muito úteis. O relatório ideal inclui:

- fornecedor e modelo testado;
- comando usado para configurar;
- resultado de `pepe model test`;
- um prompt simples que respondeu em streaming;
- um prompt que exigiu uma ferramenta, como ler ficheiros ou pesquisar na web.

Se algo falhar, abre uma issue com esse contexto. Mesmo um “testei e funciona”
ajuda a saber que integrações estão saudáveis.

