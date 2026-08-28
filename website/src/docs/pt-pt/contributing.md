---
title: Como ajudar
description: Formas de ajudar o Pepe a crescer, de issues e revisão de texto a traduções, testes de modelos e pull requests.
---

O Pepe ainda é um projeto novo, por isso qualquer ajuda pequena e bem focada já faz
diferença: abrir uma issue clara, responder a dúvidas de outras pessoas, rever textos,
testar fornecedores, melhorar traduções, ou simplesmente enviar um PR.

## Formas úteis de ajudar

- **Abre boas issues.** Conta o que tentaste, o que esperavas, o que aconteceu de facto,
  e junta os comandos ou logs relevantes.
- **Responde a issues.** Reproduz o bug, pede os detalhes que faltam, confirma se uma
  correção resolveu mesmo o problema.
- **Melhora os textos.** Corta explicações longas, troca traduções literais por
  frases que soem naturais, e corrige exemplos que pareçam artificiais.
- **Traduz.** Mantém o inglês, o espanhol, o pt-BR e o pt-PT alinhados entre si. A parte
  a traduzir é o texto que o leitor vê; comandos, nomes de ferramentas, payloads e APIs
  ficam sempre como estão.
- **Testa modelos.** Confirma que o streaming e as chamadas de ferramenta funcionam na
  OpenAI, OpenRouter, Groq, DeepSeek, Together, Mistral, Ollama, LM Studio, vLLM e
  outros fornecedores.
- **Envia PRs pequenos.** Um bug, uma página, uma tradução ou uma melhoria por PR é
  sempre mais fácil de rever do que tudo junto.

## Do fork ao PR

1. Faz um fork do repositório no GitHub.
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

4. Cria uma branch a partir da master:

```bash
git checkout -b docs-melhora-quickstart upstream/master
```

5. Instala as dependências e corre os testes:

```bash
mix deps.get
mix test
```

6. Se a alteração for no website:

```bash
cd website
npm install
npm run dev
```

7. Faz a alteração propriamente dita. Em documentação e textos, aproveita para rever
   também os outros idiomas sempre que a mesma página já exista neles.

8. Corre a verificação final a partir da raiz do projeto:

```bash
mix precommit
```

9. Faz commit e envia para o teu fork:

```bash
git add .
git commit -m "Improve quickstart copy"
git push origin docs-melhora-quickstart
```

10. Abre um pull request contra `pepe-agent/pepe:master`, explicando o que mudou e
    porquê, com link para a issue correspondente se existir uma.

## O que faz um bom PR

Um bom PR é pequeno, tem um âmbito bem definido e é fácil de rever. Em código, junta
sempre um teste quando o comportamento muda. Em documentação, prefere frases curtas,
exemplos reais e links para páginas mais completas, em vez de repetir tudo outra vez.

## Ajudar com modelos

Relatórios sobre fornecedores são particularmente úteis. O relatório ideal inclui:

- o fornecedor e o modelo testado;
- o comando usado para o configurar;
- o resultado de `pepe model test`;
- um prompt simples que respondeu em streaming;
- um prompt que precisou de uma ferramenta, como ler um ficheiro ou pesquisar na web.

Se alguma coisa falhar, abre uma issue com esse contexto todo. E mesmo um simples "testei
e funciona" já ajuda a saber quais integrações estão de facto saudáveis.
