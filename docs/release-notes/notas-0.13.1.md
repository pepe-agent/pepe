# Notas da Versão — 0.13.1

Uma versão com um assunto só: **o pedido de permissão explica por que está perguntando de novo**.

---

## 🔧 Melhoria

### O prompt de permissão agora se explica no meio de uma tarefa

Depois que um agente lê algo de fora da conversa (uma página buscada, o resultado de uma tool MCP), o turno fica marcado como "não confiável" — e enquanto isso dura, uma aprovação de "sessão" ou "sempre" já concedida deixa de valer, por segurança. Só "Permitir pelo resto desta tarefa" continua funcionando nesse período.

O problema é que, até aqui, os botões apareciam todos com o mesmo peso, sem explicação nenhuma. Quem clicava em "sessão" ou "sempre" por hábito era pego de surpresa: a próxima chamada arriscada pedia permissão de novo, e não dava pra saber por quê. Numa tarefa que devia levar 2 ou 3 cliques, viravam 10.

Agora o prompt diz, na hora: *"Esta tarefa leu algo de fora da conversa, então uma aprovação de 'sessão'/'sempre' já concedida não vale aqui. Escolha 'Permitir pelo resto desta tarefa' para parar de perguntar de novo pelo resto dela."* — e o botão certo vem marcado como **recomendado**. No painel, ele também ganha destaque visual.

Vale para as três formas de conversar com o Pepe: Telegram, chat do painel e terminal (`pepe chat`).

📍 *Onde ver: qualquer prompt de permissão que aparecer depois de o agente ler algo de fora*
