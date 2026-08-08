// LiveView hooks. Keep each one small and single-purpose; anything that needs markup
// as well as behaviour belongs in a colocated hook next to its component instead.

// Copies the value of `data-copy` (or the element's own text) to the clipboard and pushes
// `copied` back to the LiveView so it can flash a confirmation. The share screen's
// "Copy link" is the only caller today.
const Clipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const text = this.el.dataset.copy || this.el.textContent.trim()
      try {
        await navigator.clipboard.writeText(text)
        this.pushEvent("copied", {})
      } catch (_err) {
        // Clipboard access is denied outside a secure context and in some embedded
        // webviews. Fall back to selecting the text so the user can copy it by hand
        // rather than leaving a button that silently does nothing.
        const target = document.getElementById(this.el.dataset.copyFallbackId)
        if (target) {
          const range = document.createRange()
          range.selectNodeContents(target)
          const sel = window.getSelection()
          sel.removeAllRanges()
          sel.addRange(range)
        }
        this.pushEvent("copy_failed", {})
      }
    })
  },
}

// The native share sheet behind the design's Messages/WhatsApp/Slack row. The row is
// hidden entirely when the browser has no Web Share API, rather than showing app icons
// that do nothing.
const NativeShare = {
  mounted() {
    if (!navigator.share) {
      this.el.hidden = true
      return
    }
    this.el.hidden = false
    this.el.addEventListener("click", async () => {
      try {
        await navigator.share({
          title: this.el.dataset.shareTitle,
          text: this.el.dataset.shareText,
          url: this.el.dataset.shareUrl,
        })
      } catch (_err) {
        // The user dismissed the sheet. Not an error worth reporting.
      }
    })
  },
}

// Drag-to-reorder for the review screen's pool. Uses the HTML5 drag events on desktop and
// pointer events on touch, and pushes the resulting id order to the LiveView, which is the
// only thing that decides the real order — the DOM change here is optimistic.
const Sortable = {
  mounted() {
    this.dragging = null

    this.el.addEventListener("dragstart", (e) => {
      const row = e.target.closest("[data-sortable-id]")
      if (!row) return
      this.dragging = row
      row.classList.add("opacity-50")
      e.dataTransfer.effectAllowed = "move"
    })

    this.el.addEventListener("dragover", (e) => {
      if (!this.dragging) return
      e.preventDefault()
      const over = e.target.closest("[data-sortable-id]")
      if (!over || over === this.dragging) return
      const rect = over.getBoundingClientRect()
      const after = e.clientY > rect.top + rect.height / 2
      this.el.insertBefore(this.dragging, after ? over.nextSibling : over)
    })

    this.el.addEventListener("dragend", () => {
      if (!this.dragging) return
      this.dragging.classList.remove("opacity-50")
      this.dragging = null
      this.pushOrder()
    })
  },

  pushOrder() {
    const ids = Array.from(this.el.querySelectorAll("[data-sortable-id]")).map(
      (el) => el.dataset.sortableId
    )
    this.pushEvent("reorder", {ids})
  },
}

export default {Clipboard, NativeShare, Sortable}
