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

## Docker

Prefere container? `docker pull ghcr.io/pepe-agent/pepe` (amd64 e arm64). Ele precisa de um
volume e de uma senha do painel. Os dois estão explicados, junto de como dar ferramentas
extras ao agente dentro do container, na [página de Docker](/pt-br/docs/docker/).

## Desinstalar

Remova o binário; apague também a pasta de configuração para descartar todo
modelo, agente e credencial que você configurou.

```bash
rm ~/.local/bin/pepe
rm -rf ~/.pepe   # opcional: também descarta sua configuração
```

(`~/.local/bin` é a pasta padrão de instalação; se você sobrescreveu com
`$PEPE_BIN_DIR`, é para onde essa variável apontar.)
