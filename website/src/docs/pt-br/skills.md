---
title: Skills
description: Instale instruções reutilizáveis que ensinam fluxos repetíveis aos agentes.
---

Skills são instruções Markdown reutilizáveis que ensinam um agente a executar um fluxo de trabalho. As nativas ficam em `priv/skills/` e podem ser instaladas para que os agentes as descubram e apliquem durante uma execução.

## O registro: como as ferramentas são encontradas

`Pepe.Tools` é o registro único. Ele combina duas fontes.

- O conjunto **embutido**, uma lista fixa em `Pepe.Tools`. Inclui `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file` e as ferramentas de gestão que um agente
  usa para operar o runtime pela conversa (`manage_agent`, `manage_channel`,
  `enable_tool`, `schedule_task` e outras).
- Os **plugins**, descobertos em tempo de execução a partir da pasta de plugins.

`Pepe.Tools.all/0` devolve as embutidas seguidas de cada ferramenta de plugin
carregada. Quando você lista as ferramentas de um agente, cada nome é procurado
aqui. Há uma regra que vale conhecer: em uma colisão de nomes, a embutida ganha.
Você não consegue sobrepor `read_file` com um plugin de mesmo nome, então escolha
um nome distinto para a sua ferramenta.

### Conceder uma ferramenta a um agente

Um plugin instalado não entrega automaticamente suas ferramentas a todo agente.
Só as ferramentas que você lista em um agente ficam expostas a ele, e cada
chamada ainda passa pela mesma porteira de permissão de uma ferramenta embutida.
Você concede uma ferramenta de três maneiras.

**Com a CLI do pepe.** Liste a ferramenta no `--tools` do agente:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**No painel.** Abra o agente em Agentes e marque a ferramenta na lista de
ferramentas dele. As ferramentas do plugin aparecem ao lado das embutidas.

#### Faça pela conversa

Um agente que tem a ferramenta embutida `enable_tool` pode ligar uma ferramenta
para si mesmo depois que você instala um plugin, sem que você mexa na CLI ou no
painel.

> Você: ative a ferramenta reverse_text
>
> Agente: reverse_text ativada; você já pode usar a partir da sua próxima mensagem

`enable_tool` só aceita uma ferramenta que já existe como embutida ou como plugin
carregado, e a mudança vale a partir da próxima mensagem do agente. Para conceder
uma ferramenta a um agente *diferente*, um agente com a ferramenta `manage_agent`
pode fazer isso com a ação `add_tool`. Essa ferramenta é limitada aos agentes que
o agente que age tem permissão para gerenciar, e as instruções dele mandam
confirmar a mudança com você antes de aplicar.

> Você: de ao agente de suporte a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirma?
>
> Você: sim
>
> Agente: gmail_search adicionada ao support.
