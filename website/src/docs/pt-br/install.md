---
title: Instalação
description: Instale o Pepe e rode a configuração guiada antes de criar seus agentes.
---

Primeiro instale o binário `pepe`, depois rode a configuração guiada. Ela se encarrega de criar o arquivo de configuração, conectar um modelo e montar o seu primeiro agente.

## 1. Instalação

Um comando só instala o binário `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Confira se deu certo:

```bash
pepe help
```

O Pepe guarda tudo em `~/.pepe/config.json`. Não existe banco de dados nenhum para manter rodando.

## 2. Configuração guiada (o caminho mais rápido)

O `pepe setup` te leva pela mão em cada etapa: entrar no provedor do modelo, escolher qual modelo usar, criar o primeiro agente e, se você quiser, conectar um canal também.

```bash
pepe setup
```

Prefere fazer manualmente? As páginas de modelos, agentes e canais servem para isso, e os dois caminhos terminam escrevendo a mesma configuração.

<div class="note"><strong>Segredo nenhum vai para o arquivo.</strong> Quando o Pepe pede uma chave de API, ele aceita uma referência no formato <code>${ENV_VAR}</code>, por exemplo <code>${OPENROUTER_API_KEY}</code>. É essa referência que acaba gravada em <code>~/.pepe/config.json</code>. O valor de verdade é lido do seu ambiente na hora de rodar, e nunca fica guardado expandido em lugar nenhum.</div>

## Docker

Prefere container? `docker pull ghcr.io/pepe-agent/pepe` (amd64 e arm64). Você vai precisar de um volume e de uma senha para o painel; os dois estão explicados, junto com o passo a passo para dar ferramentas extras ao agente dentro do container, na [página de Docker](/pt-br/docs/docker/).

## Desinstalando

Remova o binário e, se quiser descartar também todo modelo, agente e credencial que você configurou, apague a pasta de configuração junto.

```bash
rm ~/.local/bin/pepe
rm -rf ~/.pepe   # opcional: também descarta sua configuração
```

(`~/.local/bin` é a pasta padrão de instalação; se você tiver sobrescrito isso com `$PEPE_BIN_DIR`, é para lá que essa variável estiver apontando.)
