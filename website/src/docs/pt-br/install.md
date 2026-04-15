---
title: Instalação
description: Instale o Pepe e rode a configuração guiada antes de criar agentes.
---

Instale o binário `pepe` e rode a configuração guiada. Ela cria o arquivo de
configuração, conecta um modelo e cria o primeiro agente.

## 1. Instalação

Um único comando instala o binário `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Confira que ele foi instalado:

```bash
pepe help
```

O Pepe guarda a configuração em `~/.pepe/config.json`. Não há banco de dados para
rodar.

## 2. Configuração guiada (o caminho rápido)

O `pepe setup` passa por autenticação do provedor, escolha do modelo, primeiro
agente e canais opcionais.

```bash
pepe setup
```

Se preferir fazer tudo manualmente, use as páginas de modelos, agentes e canais.
Os dois caminhos escrevem a mesma configuração.

<div class="note"><strong>Os segredos ficam fora do arquivo.</strong> Quando o Pepe pede uma chave de API, ele aceita uma referência <code>${ENV_VAR}</code>, por exemplo <code>${OPENROUTER_API_KEY}</code>. O que é escrito em <code>~/.pepe/config.json</code> é a referência. O valor real é lido do seu ambiente em tempo de execução e nunca é guardado expandido.</div>
