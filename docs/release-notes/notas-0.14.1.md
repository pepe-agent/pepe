# Notas da Versão — 0.14.1

Uma versão com um assunto só: **a tela de Configuração agora não espreme mais o editor de config.json**.

---

## 🐛 Correção

### O editor de config.json agora tem uma altura mínima garantida

Na versão 0.14.0, tentamos resolver o problema onde a lista de histórico de mudanças tomava tanto espaço que o editor de `config.json` ficava minúsculo e quase inutilizável. Aquela correção limitou só o tamanho do histórico, mas o editor em si continuava sem um tamanho mínimo garantido, então ainda encolhia até quase desaparecer toda vez que a página tinha muita coisa para mostrar (histórico + seção de Mídia).

Agora o editor tem um tamanho mínimo garantido, então a página rola até ele em vez de espremê-lo. Se você tem muitas mudanças recentes ou muita mídia configurada, a página continua mostrando tudo, só que agora em ordem, com cada seção no seu próprio espaço.

📍 *Onde ver: Painel › Configuração*

---

*Atualizado em 08/08/2026*
