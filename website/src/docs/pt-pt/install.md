---
title: Instalação
description: Instala o Pepe e corre a configuração guiada antes de criares agentes.
---

Instala o binário `pepe` e depois corre a configuração guiada. Ela trata de
criar o ficheiro de configuração, ligar um modelo e criar o teu primeiro
agente.

## 1. Instalar

Um único comando instala o binário `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Confirma que ficou tudo no lugar:

```bash
pepe help
```

O Pepe guarda a sua configuração em `~/.pepe/config.json`. Não há nenhuma
base de dados para correr à parte.

## 2. Configuração guiada (o caminho rápido)

O `pepe setup` conduz-te por tudo: iniciar sessão junto do fornecedor do
modelo, escolher um modelo, criar o teu primeiro agente e, se quiseres,
ligar também um canal.

```bash
pepe setup
```

Se preferires fazer cada passo à mão, usa as páginas de modelos, agentes e
canais em separado. Seja qual for o caminho, o resultado é a mesma
configuração escrita no mesmo sítio.

<div class="note"><strong>Os segredos não entram no ficheiro.</strong> Quando o Pepe te pede uma chave de API, aceita uma referência <code>${ENV_VAR}</code>, por exemplo <code>${OPENROUTER_API_KEY}</code>. É essa referência, e não o valor, que fica escrita em <code>~/.pepe/config.json</code>. O valor verdadeiro só é lido do teu ambiente em tempo de execução e nunca chega a ser guardado expandido.</div>

## Docker

Preferes um contentor? `docker pull ghcr.io/pepe-agent/pepe` (amd64 e
arm64). Precisas de um volume e de uma palavra-passe para o painel; os dois
estão explicados, junto com a forma de dar ao agente ferramentas extra
dentro do contentor, na [página de Docker](/pt-pt/docs/docker/).

## Desinstalar

Remover o binário chega para tirar o Pepe da máquina; apaga também a pasta
de configuração se quiseres livrar-te de todo o modelo, agente e credencial
que tenhas configurado.

```bash
rm ~/.local/bin/pepe
rm -rf ~/.pepe   # opcional, também apaga a tua configuração
```

(`~/.local/bin` é a pasta de instalação predefinida; se sobrepuseste isso
com `$PEPE_BIN_DIR`, é para lá que deves olhar em vez disso.)
