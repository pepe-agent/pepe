---
title: Delegação (fan-out)
description: A ferramenta delegate divide um trabalho amplo em workers paralelos descartáveis, cada um com a própria janela de contexto nova, então o todo demora o tempo da parte mais lenta, e não a soma.
---

"Compare estes oito concorrentes" não é uma tarefa, são oito, e fazer isso em uma única conversa custa o dobro. Demora oito vezes mais. E cada página buscada para o concorrente um continua ocupando a janela de contexto enquanto o modelo lê sobre o concorrente oito, então a janela enche de material que ninguém vai olhar de novo, e a resposta final piora junto.

A ferramenta `delegate` entrega as partes a workers descartáveis, todas de uma vez:

```
você › compare as páginas de preços da stripe, da adyen e da mollie

agente › delegate(tasks: [
           "Leia stripe.com/pricing e informe a taxa de cartão e qualquer mínimo mensal.",
           "Leia adyen.com/pricing e informe a taxa de cartão e qualquer mínimo mensal.",
           "Leia mollie.com/pricing e informe a taxa de cartão e qualquer mínimo mensal."
         ])
```

Cada worker é uma execução nova, com a própria janela de contexto e o próprio trace. Ele lê o que precisa, responde à pergunta que recebeu e desaparece. O pai recebe três respostas e nunca vê as três transcrições, então o trabalho cabe numa janela em que antes não caberia. E, como os workers esperam a rede ao mesmo tempo, o conjunto demora o tempo do mais lento, não a soma.

## Dando a ferramenta a um agente

Você concede o `delegate` do jeito de sempre, na lista de ferramentas:

```bash
pepe agent add lead --model openrouter --tools fetch_url,read_file,delegate
```

## Um worker pode ler; não pode agir

Um worker herda apenas as ferramentas que não pedem permissão: `read_file`, `list_dir`, `fetch_url`, `web_search` e afins. Tudo o que escreve, executa, instala ou apaga é retirado antes de o worker começar, e um worker não pode delegar de novo.

Isso não é uma limitação esperando para ser removida. Três workers rodando ao mesmo tempo são três workers que iam querer fazer três perguntas a você ao mesmo tempo, e *posso rodar isto?* não é uma pergunta para se fazer em triplicata. Mais importante: o fan-out serve para **descobrir**, e descobrir é seguro de fazer em paralelo. **Agir** não é, e continua onde deve ficar, na única conversa que você está de fato acompanhando. Um worker que descobre que algo precisa ser feito diz isso, e o pai o faz, na barreira de permissão, na sua frente.

A outra proteção é aritmética. Sem o "um worker não pode delegar", uma tarefa vira oito, vira sessenta e quatro, e a conta chega antes da resposta.

<div class="note"><strong>Um teto rígido de oito tarefas por chamada.</strong> O modelo é avisado do teto, então ele divide o trabalho em vez de ser surpreendido por ele.</div>

## Delegando como outro agente

```
delegate(tasks: [...], agent: "researcher")
```

Isso roda os workers como um agente diferente, com a persona e as ferramentas desse agente, ainda sem nada que aja. Vale a mesma lista de permissão dirigida do `send_to_agent`: um agente só pode tomar emprestada a identidade de outro se já tinha permissão para mandar mensagem para ele. Uma autoridade para o ato, não uma segunda e mais fraca. As rotas estão explicadas na página [Agentes](../agents/).

## Quanto custa

Cada worker é uma chamada de modelo de verdade, medida e cobrada como qualquer outra, no mesmo projeto. Oito workers são oito turnos. É essa a troca: você está comprando de volta tempo de relógio e espaço na janela de contexto, e pagando por isso em tokens. Para uma tarefa que não caberia em uma única janela, nem chega a ser uma troca.

Cada worker ganha o próprio trace, então **Traces** no [painel](../dashboard/) mostra o que cada um realmente fez, não só o que o pai disse a respeito.
