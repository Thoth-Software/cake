// Keeps the newest message of the chat in view as the conversation grows
// (CakeWeb.ChatLive, on #chat).
//
// The chat scrolls with the page, under a bar that sticks to the bottom of
// the screen. While the reader is at the bottom, an update that makes the
// page taller scrolls it back down to the bottom. Scrolling up to read stops
// that, so an answer arriving does not pull the page away; scrolling back
// down, or sending a question, starts it again.

// How close to the bottom still counts as being there, in pixels.
const NEAR = 80

const pageHeight = () => document.documentElement.scrollHeight

const atBottom = () => window.innerHeight + window.scrollY >= pageHeight() - NEAR

const FollowNewest = {
  mounted() {
    this.following = true
    this.onScroll = () => { this.following = atBottom() }
    this.onSubmit = () => { this.following = true }

    window.addEventListener("scroll", this.onScroll, {passive: true})
    this.el.addEventListener("submit", this.onSubmit)
    this.toNewest()
    this.height = pageHeight()
  },

  // An update does not scroll the page, so `following` still says where the
  // reader was before it. Most updates add nothing (each keystroke in the
  // question box is one), and those leave the page where it is.
  updated() {
    const grew = pageHeight() > this.height
    this.height = pageHeight()

    // The candidates arrive as one block that can be taller than the screen.
    // Its end is not where to start reading it: show its heading instead.
    const panel = this.el.querySelector("#selection-panel")
    const panelArrived = panel && !this.panelShown
    this.panelShown = Boolean(panel)

    if (!this.following || !grew) return

    if (panelArrived && panel.offsetHeight > window.innerHeight / 2) {
      panel.scrollIntoView({block: "start", behavior: "instant"})
    } else {
      this.toNewest()
    }
  },

  destroyed() {
    window.removeEventListener("scroll", this.onScroll)
  },

  // Not a smooth scroll: its intermediate positions would read as the
  // reader scrolling up.
  toNewest() {
    window.scrollTo({top: pageHeight(), behavior: "instant"})
  },
}

export default FollowNewest
