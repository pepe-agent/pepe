# Notas da Versão — 0.17.0

Uma versão focada em **grupo do Telegram**, **permissões mais inteligentes** e **menos distrações** quando algo não está configurado.

---

## ✨ Novidades

### Duas novas opções de permissão para deixar o agente trabalhar sem interrupções

Quando você permite que o agente use uma ferramenta, agora tem mais escolhas:

**"Permitir tudo para esta tarefa"** — autoriza o agente a usar qualquer ferramenta pelo resto dessa tarefa específica, sem mais perguntas. Se ele precisar ler um arquivo, rodar um comando e buscar uma página, tudo acontece numa sequência só, sem você ter que clicar três vezes. Expira assim que essa tarefa termina; a próxima mensagem já volta a perguntar normalmente.

**"⚠️ Permitir tudo para esta sessão"** — mais permissivo ainda: não pergunta mais nada até você digitar `/novo` ou reiniciar. Use quando confia no agente o tempo todo, naquele momento. Tem um aviso (⚠️) na própria opção para deixar claro que é uma concessão maior.

Ambas aparecem em todo lugar: no Telegram, no dashboard e na linha de comando.

📍 *Onde ver: em qualquer prompt de permissão*

---

## ⚡ Mudanças

### No Telegram em grupo, só a mensagem mais recente mostra quem enviou

Quando várias pessoas falam num grupo do Telegram, o agente agora sabe ao certo quem foi a última pessoa a falar — antes, ele podia ficar repetindo o nome da pessoa anterior mesmo depois que outra pessoa tinha respondido.

A forma como o agente enxerga isso também mudou: antes cada mensagem guardava o nome de quem enviou, daqui pra frente só a mensagem atual carrega essa informação, de um jeito que não atrapalha o resto da conversa.

---

## 🔧 Melhorias

### Langfuse agora se liga sozinho com as mesmas credenciais que você já usa

Se você já configurou a exportação de traços para o Langfuse, tudo fica mais simples: o Pepe agora encontra suas chaves `LANGFUSE_PUBLIC_KEY` e `LANGFUSE_SECRET_KEY` (as mesmas que você usa para prompts gerenciáveis no Langfuse) e começa a exportar os traços automaticamente. Sem precisar de variáveis de ambiente diferentes.

Se você precisa usar um backend OTLP diferente, aquelas variáveis antigas (`OTEL_EXPORTER_OTLP_*`) continuam funcionando e têm prioridade.

---

## 🐛 Correções

### O agente não reclama mais de credencial faltando quando na verdade só não consegue ver

Quando o agente verifica um segredo (uma chave de API, um token) e vê que está vazio, agora ele sabe a diferença:

- Vazio porque ninguém nunca configurou (credencial de verdade faltando)
- Vazio porque o operador (você) deliberadamente não deixou o agente ver (a credencial existe, mas está ocultada)

Antes, o agente achava que era falta de credencial em ambos os casos e reclamava pro usuário. Agora só avisa quando de verdade está faltando.

---

*Atualizado em 12/08/2026*
