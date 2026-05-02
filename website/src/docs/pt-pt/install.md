---
title: Instalação
description: Instala o Pepe e executa a configuração guiada antes de criares agentes.
---

Instala o binário `pepe` e executa a configuração guiada. Cria o ficheiro de
configuração, liga um modelo e cria o primeiro agente.

## 1. Instalação

Um único comando instala o binário `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Confirma que ficou instalado:

```bash
pepe help
```

O Pepe guarda a configuração em `~/.pepe/config.json`. Não há base de dados para
executar.

## 2. Configuração guiada (o caminho rápido)

O `pepe setup` passa por autenticação do fornecedor, escolha do modelo, primeiro
agente e canais opcionais.

```bash
pepe setup
```

Se preferires fazer tudo manualmente, usa as páginas de modelos, agentes e canais.
Os dois caminhos escrevem a mesma configuração.

<div class="note"><strong>Os segredos ficam fora do ficheiro.</strong> Quando o Pepe pede uma chave de API, aceita uma referência <code>${ENV_VAR}</code>, por exemplo <code>${OPENROUTER_API_KEY}</code>. O que fica escrito em <code>~/.pepe/config.json</code> é a referência. O valor real é lido do teu ambiente em tempo de execução e nunca fica guardado expandido.</div>

## Docker

Prefere um contentor? `docker pull ghcr.io/pepe-agent/pepe` (amd64 e arm64). Precisa de um
volume e de uma palavra-passe do painel - ambos estão explicados, a par de como dar
ferramentas extra ao agente dentro do contentor, na [página de Docker](/pt-pt/docs/docker/).

## Desinstalar

Remove o binário; apaga também a pasta de configuração para descartares todo
modelo, agente e credencial que configuraste.

```bash
rm ~/.local/bin/pepe
rm -rf ~/.pepe   # opcional - também descarta a tua configuração
```

(`~/.local/bin` é a pasta predefinida de instalação; se sobrescreveste com
`$PEPE_BIN_DIR`, é para onde ele apontar.)
