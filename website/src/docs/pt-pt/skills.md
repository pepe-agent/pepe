---
title: Skills
description: Instala instruções reutilizáveis que ensinam fluxos repetíveis aos agentes.
---

Skills são instruções Markdown reutilizáveis que ensinam um agente a executar um fluxo de trabalho. As nativas ficam em `priv/skills/` e podem ser instaladas para que os agentes as descubram e apliquem durante uma execução.

## O registo: como as ferramentas são encontradas

`Pepe.Tools` é o registo único. Combina duas fontes.

- O conjunto **incorporado**, uma lista fixa em `Pepe.Tools`. Inclui `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file` e as ferramentas de gestão que um agente
  usa para operar o runtime pela conversa (`manage_agent`, `manage_channel`,
  `enable_tool`, `schedule_task` e outras).
- Os **plugins**, descobertos em tempo de execução a partir da pasta de plugins.

`Pepe.Tools.all/0` devolve as incorporadas seguidas de cada ferramenta de plugin
carregada. Quando listas as ferramentas de um agente, cada nome é procurado
aqui. Há uma regra que vale a pena conhecer: numa colisão de nomes, a
incorporada ganha. Não consegues sobrepor `read_file` com um plugin do mesmo
nome, por isso escolhe um nome distinto para a tua ferramenta.

### Conceder uma ferramenta a um agente

Um plugin instalado não entrega automaticamente as suas ferramentas a todos os
agentes. Só as ferramentas que listas num agente ficam expostas a ele, e cada
chamada continua a passar pela mesma cancela de permissão de uma ferramenta
incorporada. Concedes uma ferramenta de três formas.

**Com a CLI do pepe.** Lista a ferramenta no `--tools` do agente:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**No painel.** Abre o agente em Agentes e assinala a ferramenta na lista de
ferramentas dele. As ferramentas do plugin aparecem ao lado das incorporadas.

#### Fá-lo pela conversa

Um agente que tem a ferramenta incorporada `enable_tool` pode ligar uma
ferramenta para si mesmo depois de instalares um plugin, sem teres de mexer na
CLI ou no painel.

> Tu: ativa a ferramenta reverse_text
>
> Agente: reverse_text ativada; já podes usá-la a partir da tua próxima mensagem

`enable_tool` só aceita uma ferramenta que já existe como incorporada ou como
plugin carregado, e a mudança vale a partir da próxima mensagem do agente.
Para conceder uma ferramenta a um agente *diferente*, um agente com a
ferramenta `manage_agent` consegue fazê-lo com a ação `add_tool`. Essa
ferramenta está limitada aos agentes que o agente que atua tem permissão para
gerir, e as instruções dele mandam confirmar a mudança contigo antes de a
aplicar.

> Tu: dá ao agente de suporte a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirmas?
>
> Tu: sim
>
> Agente: gmail_search adicionada ao support.
