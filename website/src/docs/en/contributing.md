---
title: How to help
description: Help with issues, copy review, translations, model testing, and pull requests.
---

Pepe is young. Small, focused help already matters: opening a clear issue,
answering questions, reviewing copy, testing providers, improving translations, or
sending a PR.

## Useful ways to help

- **Open good issues.** Say what you tried, what you expected, what happened, and
  include relevant commands or logs.
- **Answer issues.** Reproduce bugs, ask for missing details, and confirm whether
  a fix works.
- **Improve copy.** Cut long explanations, replace literal translations with
  natural wording, and fix examples that feel artificial.
- **Translate.** Keep English, Spanish, pt-BR, and pt-PT aligned. Translate reader
  text; preserve commands, tool names, payloads, and APIs.
- **Test models.** Confirm streaming and tool calling on OpenAI, OpenRouter, Groq,
  DeepSeek, Together, Mistral, Ollama, LM Studio, vLLM, and other providers.
- **Send small PRs.** One bug, one page, one translation, or one improvement per PR
  is easier to review.

## From fork to PR

1. Fork the repository on GitHub.
2. Clone your fork:

```bash
git clone git@github.com:YOUR_USER/pepe.git
cd pepe
```

3. Add the original repository as upstream:

```bash
git remote add upstream https://github.com/pepe-agent/pepe.git
git fetch upstream
```

4. Create a branch from master:

```bash
git checkout -b docs-improve-quickstart upstream/master
```

5. Install dependencies and run tests:

```bash
mix deps.get
mix test
```

6. If you are changing the website:

```bash
cd website
npm install
npm run dev
```

7. Make the change. For docs and copy, review the other languages when the same
page exists in them.

8. Run the final check from the project root:

```bash
mix precommit
```

9. Commit and push to your fork:

```bash
git add .
git commit -m "Improve quickstart copy"
git push origin docs-improve-quickstart
```

10. Open a pull request against `pepe-agent/pepe:master`. Explain what changed, why
it changed, and link the issue if there is one.

## Good PRs

A good PR is small, scoped, and easy to review. For code, include a test when
behavior changes. For docs, prefer short sentences, real examples, and links to
deeper pages instead of repeating everything.

## Help with models

Provider reports are especially useful. The ideal report includes:

- provider and model tested;
- command used to configure it;
- output of `pepe model test`;
- a simple prompt that streamed a response;
- a prompt that required a tool, such as reading a file or searching the web.

If something fails, open an issue with that context. Even a “tested and works”
report helps track which integrations are healthy.

