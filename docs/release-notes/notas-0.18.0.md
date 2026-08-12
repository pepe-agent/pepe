# Notas da Versão — 0.18.0

Uma versão focada em **instalar skills com nomes curtos** e **traços mais ricos no Langfuse**.

---

## ✨ Novidades

### Instalar skills e plugins usando o PepeHub

Antes, para instalar um skill ou plugin você tinha que colar uma URL longa ou lembrar exatamente como o arquivo se chamava. Agora você pode usar nomes curtos direto do PepeHub, o mercado de skills e plugins do Pepe.

**Dois jeitos fazem a mesma coisa:**
- `mix pepe skill install @handle/nome`: use o nome curto
- `mix pepe skill install https://hub.pepe-agent.com/...`: ou copie a URL da página

Se errar e tentar instalar algo com `plugin install` que na verdade é um skill (ou vice-versa), o Pepe avisa qual comando usar no lugar.

Tudo isso funciona porque o Pepe agora consegue baixar e descompactar arquivos `.zip` mesmo quando a URL não tem extensão, exatamente o que o PepeHub oferece.

📍 *Onde encontrar: terminal com `mix pepe skill install` ou `mix pepe plugin install`*

---

### Gerenciar skills pela conversa com `manage_skill`

Antes, só `manage_plugin` deixava você gerenciar plugins desde dentro de uma conversa com o agente. Agora tem o equivalente para skills: a ferramenta `manage_skill`.

Com ela você pode:
- **Buscar** skills no mercado
- **Instalar** um skill por nome curto ou URL
- **Atualizar** skills já instalados
- **Remover** um skill que não precisa mais
- **Revisar** um skill antes de confiar

É exatamente o mesmo que `mix pepe skill ...` na linha de comando, mas conversacionalmente: você pede ao agente em vez de rodar comandos na mão.

📍 *Onde encontrar: quando conversa com um agente que tem essa ferramenta ativada*

---

## ⚡ Mudanças

### Langfuse agora recebe muito mais contexto sobre cada execução

Se você monitora seus agentes no Langfuse, os traços que o Pepe manda ficaram bem mais informativos. Agora cada execução inclui:

- **De que canal veio:** Telegram, API, ou outro
- **Quem está rodando:** o identificador único da conversa (marcado honestamente como de nível de chat, não por pessoa, em canais compartilhados como grupos do Telegram)
- **Que versão do Pepe estava rodando** naquele momento
- **Como terminou:** normal, aviso ou erro
- **Quanto custou cada chamada ao modelo**, omitido quando não temos preço tabelado, em vez de mostrar um zero enganoso

Isso torna muito mais fácil debugar, medir e otimizar seus agentes: você vê não só o que aconteceu, mas por quanto, de onde, e como terminou.

---

*Atualizado em 12/08/2026*
