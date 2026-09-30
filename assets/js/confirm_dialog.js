// The dashboard's own confirmation dialog.
//
// Any element with a `data-confirm="message"` attribute (a delete button, a "restart" button, ...)
// used to open the browser's native `window.confirm`, which ignores the dashboard's look, cannot be
// styled and reads differently in every browser. This intercepts the click before Phoenix or
// LiveView sees it, asks in a dialog of our own, and only if the answer is yes lets the original
// click through, with the attribute lifted for that one click so nothing asks a second time.
//
// The button labels come from the page (`data-confirm-ok` / `data-confirm-cancel` on <body>, set
// in the root layout with gettext) so the dialog speaks the dashboard's language.

// A message about deleting, clearing or resetting gets a red confirm button, so a destructive
// answer looks different from "yes, restart".
const DESTRUCTIVE = /\b(delete|remove|erase|clear|revoke|discard|reset|archive|cancel|excluir|remover|apagar|limpar|revogar|descartar|zerar|arquivar|cancelar|eliminar|borrar|revocar|restablecer)\b/i

const GHOST =
  "inline-flex items-center justify-center gap-2 rounded-[12px] border border-white/[.12] h-[44px] px-[18px] text-[14.5px] text-zinc-400 transition hover:border-white/25 hover:text-zinc-100"
const PRIMARY =
  "inline-flex items-center justify-center gap-2 rounded-[12px] bg-orange-400 h-[44px] px-[18px] text-[14.5px] font-semibold text-on-accent transition hover:bg-orange-300"
const DANGER =
  "inline-flex items-center justify-center gap-2 rounded-[12px] bg-danger-ink h-[44px] px-[18px] text-[14.5px] font-semibold text-on-accent transition hover:opacity-90"

function ask(message) {
  const labels = document.body.dataset
  const destructive = DESTRUCTIVE.test(message)

  return new Promise((resolve) => {
    const previous = document.activeElement

    const overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-[100] grid place-items-center bg-black/60 px-4 backdrop-blur-[2px]"

    const card = document.createElement("div")
    card.setAttribute("role", "alertdialog")
    card.setAttribute("aria-modal", "true")
    card.setAttribute("aria-describedby", "pepe-confirm-message")
    card.className =
      "w-full max-w-md rounded-[14px] border border-white/[.12] bg-[#0f1921] p-6 text-zinc-100 shadow-2xl shadow-black/60"

    const text = document.createElement("p")
    text.id = "pepe-confirm-message"
    text.className = "whitespace-pre-line text-[15px] leading-relaxed text-zinc-200"
    text.textContent = message

    const actions = document.createElement("div")
    actions.className = "mt-6 flex justify-end gap-2"

    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.className = GHOST
    cancel.textContent = labels.confirmCancel || "Cancel"

    const ok = document.createElement("button")
    ok.type = "button"
    ok.className = destructive ? DANGER : PRIMARY
    ok.textContent = labels.confirmOk || "OK"

    actions.append(cancel, ok)
    card.append(text, actions)
    overlay.append(card)
    document.body.append(overlay)

    const finish = (answer) => {
      document.removeEventListener("keydown", onKey, true)
      overlay.remove()
      if (previous && previous.isConnected) previous.focus()
      resolve(answer)
    }

    const onKey = (event) => {
      if (event.key === "Escape") {
        event.preventDefault()
        finish(false)
      } else if (event.key === "Tab") {
        // Two buttons: keep focus inside the dialog.
        event.preventDefault()
        ;(document.activeElement === cancel ? ok : cancel).focus()
      }
    }

    cancel.addEventListener("click", () => finish(false))
    ok.addEventListener("click", () => finish(true))
    overlay.addEventListener("mousedown", (event) => {
      if (event.target === overlay) finish(false)
    })
    document.addEventListener("keydown", onKey, true)

    // Land on the safe choice for a destructive question, on the action otherwise.
    ;(destructive ? cancel : ok).focus()
  })
}

// Capture phase on window, registered before LiveView connects: this runs before phoenix_html's and
// LiveView's own click handlers, which are the ones that would call window.confirm.
window.addEventListener(
  "click",
  async (event) => {
    const el = event.target instanceof Element ? event.target.closest("[data-confirm]") : null
    if (!el) return

    const message = el.getAttribute("data-confirm")
    if (!message) return

    event.preventDefault()
    event.stopImmediatePropagation()

    if (!(await ask(message))) return
    if (!el.isConnected) return

    el.removeAttribute("data-confirm")
    el.click()
    el.setAttribute("data-confirm", message)
  },
  true,
)
