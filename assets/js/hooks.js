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

// The native share sheet behind the design's Messages/WhatsApp/Slack tiles. There is one
// button, not four: the tiles are decoration inside it, because `navigator.share` opens one
// OS sheet and cannot target a named app (see the comment in group_live/share.ex). The whole
// control is hidden when the browser has no Web Share API, rather than showing app icons
// that do nothing.
//
// **Progressive enhancement, and it has to be this way round.** The server renders the
// button with a literal `hidden` attribute and this hook *removes* it where the API
// exists. The reverse — server renders it visible, `mounted()` sets `el.hidden = true` —
// is what shipped, and it came back on the first re-render: LiveView's DOM patch restores
// the server's markup, which had no `hidden`, and `mounted()` never runs again. Measured
// on desktop Chrome (`navigator.share === undefined`): correct on load, then pressing the
// screen's own `Copy link` — which pushes `copied`/`copy_failed` and flashes, so the
// LiveView re-renders — repainted a 384×105 card of four app tiles with a hover state,
// `document.elementFromPoint` at its centre returning `native-share`, whose listener calls
// an undefined `navigator.share` and throws. A dead control on the one screen whose entire
// job is sending the link.
//
// `updated()` re-applies for the same reason, so neither direction depends on a patch not
// happening.
const NativeShare = {
  apply() {
    this.el.hidden = !navigator.share
  },
  mounted() {
    this.apply()
    this.el.addEventListener("click", async () => {
      if (!navigator.share) return
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
  updated() {
    this.apply()
  },
}

// Drag-to-reorder for the review screen's pool. Pushes the resulting id order to the
// LiveView, which is the only thing that decides the real order — the DOM change here is
// optimistic.
//
// **Mouse and stylus only.** This binds `dragstart` / `dragover` / `dragend` and nothing
// else, and no mobile browser fires HTML5 drag-and-drop from a finger. This comment used
// to claim it used "pointer events on touch"; it never has, and `/groups/:id/review` was
// telling phone users to "Drag to reorder" on the strength of it. The screen no longer
// leads with that instruction and hides its ⠿ handle wherever there is no hover; the ▲▼
// buttons beside each row are the reordering path that works everywhere, and they go
// through `move_up` / `move_down`, not through this hook. See D-045. If this ever grows a
// finger path, `SwipeCard` below is the Pointer Events shape to copy.
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

// The swipe deck's top card on /join/:slug/vote (design frame
// `docs/design/screens/1c-0-swipe-deck-kept-in-play.html`, D-044).
//
// The server holds the truth. This hook knows nothing about which options are approved
// or vetoed — it reports one decision per card ("approve" / "pass") and lets the
// LiveView update `@approved` / `@veto_id`, exactly the way `Sortable` above pushes an
// order and lets the LiveView decide it. Every gesture here has a real button below the
// card doing the same thing, so nothing depends on this file working.
//
// Pointer Events, not touch + mouse separately: one code path covers finger, mouse and
// stylus. The listeners that have to live on `window` (a drag routinely ends outside the
// card) are registered through one AbortController so `destroyed()` removes all of them —
// the card element is replaced on every decision, so a leak here would be per-card.
const SwipeCard = {
  mounted() {
    this.controller = new AbortController()
    const {signal} = this.controller
    this.suppressClick = false
    this.resetDrag()

    this.el.addEventListener(
      "pointerdown",
      (e) => {
        // Ignore secondary mouse buttons; a right-click is not a swipe.
        if (e.pointerType === "mouse" && e.button !== 0) return
        // Cleared HERE, not only where it is consumed. It used to be cleared solely inside
        // the click listener, and a click is not guaranteed to follow the gesture that set
        // it: `pointercancel` is by definition never followed by one, and a `pointerup`
        // released off the card (which is what happens when you drag and let go over the
        // control row directly below) produces no click on the card either. The flag then
        // survived and ate the voter's NEXT genuine tap — the deck's primary affordance
        // doing nothing once, silently, right after the screen said "Tap or swipe right to
        // pick it".
        this.suppressClick = false
        this.pointerId = e.pointerId
        this.startX = e.clientX
        this.startY = e.clientY
        this.dx = 0
        this.axis = null
        // Far enough to be deliberate: a bit over a quarter of the card, clamped so it is
        // neither a twitch on a wide screen nor unreachable on a narrow one. Measured ONCE
        // per gesture and used for BOTH the colour hint and the commit, so the card never
        // shows mint at a distance that would release as nothing — a 24px hint against a
        // 90px commit left a 66px band where the card promised a vote it then discarded.
        this.threshold = Math.min(90, Math.max(56, this.el.offsetWidth * 0.28))
        this.el.classList.add("is-dragging")
      },
      {signal}
    )

    window.addEventListener(
      "pointermove",
      (e) => {
        if (this.startX === null || e.pointerId !== this.pointerId) return
        const dx = e.clientX - this.startX
        const dy = e.clientY - this.startY

        // Decide once whether this gesture is a horizontal swipe or a vertical page
        // scroll, and never re-decide: a card that steals a scroll makes the page feel
        // broken on a phone.
        if (this.axis === null) {
          if (Math.abs(dx) < 6 && Math.abs(dy) < 6) return
          this.axis = Math.abs(dx) > Math.abs(dy) ? "x" : "y"
          if (this.axis === "y") return this.resetDrag()
          // Keeps the drag alive when the finger leaves the card. Wrapped because it
          // throws NotFoundError when the pointer is no longer active — which a real
          // finger can be by the time this runs, and a synthetic PointerEvent always is.
          // Losing capture degrades to the window listeners below; it is not fatal.
          try {
            if (this.el.setPointerCapture) this.el.setPointerCapture(e.pointerId)
          } catch (_err) {}
        }
        if (this.axis !== "x") return

        this.dx = dx
        const rotation = Math.max(-9, Math.min(9, dx / 14))
        this.el.style.transform = `translateX(${dx}px) rotate(${rotation}deg)`
        // Two separate signals, because they answer two different questions. `swipeDir` is
        // *which way* and lands immediately, so the card responds to the finger.
        // `swipeHint` is *this will commit* and lands at exactly the release threshold, so
        // the card never wears the full decision colour at a distance that discards it.
        this.el.style.setProperty(
          "--swipe-progress",
          Math.min(1, Math.abs(dx) / this.threshold).toFixed(3)
        )
        this.el.dataset.swipeDir = dx > 0 ? "approve" : "pass"
        this.el.dataset.swipeHint =
          dx >= this.threshold ? "approve" : dx <= -this.threshold ? "pass" : ""
      },
      {signal}
    )

    const finish = (e) => {
      if (this.startX === null || e.pointerId !== this.pointerId) return
      const dx = this.dx
      const decision =
        dx >= this.threshold ? "approve" : dx <= -this.threshold ? "pass" : null

      // A drag that moved at all must not also read as a tap — see the click listener below.
      this.suppressClick = this.axis === "x" && Math.abs(dx) > 6

      this.resetDrag()

      if (decision) {
        this.pushEvent("deck_decide", {decision, id: this.el.dataset.activityId})
      }
    }

    window.addEventListener("pointerup", finish, {signal})

    // NOT `finish`. `pointercancel` means the OS or the browser took the gesture away —
    // Android's edge back-swipe, the notification shade, a second finger landing — and the
    // finger was never lifted. Committing there hands the voter an approval they did not
    // release, on a ballot that locks on submit and cannot be recast (D-036).
    window.addEventListener(
      "pointercancel",
      (e) => {
        if (this.startX === null || e.pointerId !== this.pointerId) return
        // Nothing to suppress: a cancelled pointer never produces a click. Setting the
        // flag here only left it armed for the next tap.
        this.resetDrag()
      },
      {signal}
    )

    // A tap on the card is the pointer twin of a swipe right: the grid one switch away
    // teaches "tap the card to pick it", and the largest object on this screen answering a
    // tap with silence is the same unreadable affordance in reverse. Capture phase, on the
    // element itself, so a drag that ended in a click never double-fires — LiveView's own
    // click handling is delegated from the document and never sees a stopped event.
    //
    // Deliberately JS-only, with no `role="button"` and no `tabindex`: this is a *pointer*
    // convenience shadowing a pointer-only gesture, and its accessible peer is the real
    // `#deck-approve` button 20px below it. Making the card focusable would put a second
    // "Pick <name>" control in the tab order ahead of the one the design draws.
    this.el.addEventListener(
      "click",
      (e) => {
        if (this.suppressClick) {
          this.suppressClick = false
          e.preventDefault()
          e.stopPropagation()
          return
        }
        this.pushEvent("deck_decide", {decision: "approve", id: this.el.dataset.activityId})
      },
      {signal, capture: true}
    )
  },

  // Puts the card back where the server put it. Called on release, when the gesture
  // turns out to be a scroll, and when the pointer is cancelled by the OS.
  resetDrag() {
    this.pointerId = null
    this.startX = null
    this.startY = null
    this.dx = 0
    this.axis = null
    this.el.classList.remove("is-dragging")
    this.el.style.transform = ""
    this.el.style.removeProperty("--swipe-progress")
    this.el.dataset.swipeDir = ""
    this.el.dataset.swipeHint = ""
  },

  destroyed() {
    this.controller.abort()
  },
}

// Arms the browser's own "leave site?" prompt while there is an unsent ballot, and only
// then. `@approved` / `@veto_id` live in socket assigns until `Voting.cast_ballot/3` runs
// (D-036), so a reload — a stray pull-to-refresh on a phone, mid-deck — silently discards
// the whole walk. `beforeunload` does not fire on LiveView's own pushState navigation, so
// submitting and the `Create your own →` pill (which has its own `data-confirm`) are
// unaffected; this catches reload, close and a typed URL.
//
// The condition is read at event time from `data-unsaved`, which the server re-renders on
// every selection change, so there is no client-side copy of what is picked.
const UnsavedBallot = {
  mounted() {
    this.handler = (e) => {
      if (this.el.dataset.unsaved !== "true") return
      e.preventDefault()
      // Required by Chrome and Safari; the string itself is ignored by every modern browser.
      e.returnValue = ""
    }
    window.addEventListener("beforeunload", this.handler)
  },

  destroyed() {
    window.removeEventListener("beforeunload", this.handler)
  },
}

// Brings the field a rejected submit complained about into view, and focuses it.
//
// A LiveView that answers an invalid submit by re-rendering the form changes nothing a
// reader can necessarily see. Measured on `/feedback` at 360×640 before this existed:
// pressing the tangerine `Send feedback` rendered `tell us what happened` at y 680 in a
// 640px viewport, `scrollY` stayed 0, `document.activeElement` did not move, and
// screenshots taken either side of the press were identical. The app's one forward action
// on that screen did nothing observable.
//
// `block: "center"` rather than the default `"start"`: the page has a sticky header above
// and (on `/feedback`) a sticky action bar below, and centring is the only placement that
// clears both without the hook needing to know either one's height.
//
// **Focus first, then scroll, and no `behavior: "smooth"`.** Both halves were measured on
// `/feedback` at 360×640, scrolled to the bottom, on a rejected submit:
//
//   * scrolling before focusing left the field focused and still off-screen — `focus()`
//     cancels an in-progress smooth scroll, so `activeElement` became `entry_message`
//     while its rect sat at `top: -221`;
//   * focusing first and then scrolling *smoothly* moved the page not one pixel
//     (`scrollY` 488 before and after, 1000ms later) — a smooth `scrollIntoView` on an
//     element that was just focused with `preventScroll` is a no-op in Chrome. The same
//     call with the default instant behaviour lands it at `top: 250` in a 640px viewport.
//
// Instant is the right answer here anyway: this fires on a rejected press, and an
// animation is a delay between the press and the reader seeing why nothing was sent.
const RevealError = {
  mounted() {
    this.handleEvent("reveal-error", ({id}) => {
      const el = id && document.getElementById(id)
      if (!el) return
      if (typeof el.focus === "function") el.focus({preventScroll: true})
      el.scrollIntoView({block: "center"})
    })
  },
}

export default {Clipboard, NativeShare, RevealError, Sortable, SwipeCard, UnsavedBallot}
