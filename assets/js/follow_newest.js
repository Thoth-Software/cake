// Keeps the newest message of the chat in view as the conversation grows
// (CakeWeb.ChatLive, on #chat).
//
// The chat scrolls with the page, under a bar that sticks to the bottom of
// the screen. While the reader is at the bottom, an update that makes the
// page taller scrolls it back down to the bottom. Scrolling up to read stops
// that, so an answer arriving does not pull the page away; scrolling back
// down, or sending a question, starts it again.

// It also puts the cursor back in the question box when the box returns
// after an answer, where there is a mouse: on a touch screen, focusing it
// would open the keyboard over the answer.

// How close to the bottom still counts as being there, in pixels.
const NEAR = 80

const pageHeight = () => document.documentElement.scrollHeight

const atBottom = () => window.innerHeight + window.scrollY >= pageHeight() - NEAR

const finePointer = window.matchMedia("(pointer: fine)")

const FollowNewest = {
  mounted() {
    this.following = true
    this.onScroll = () => { this.following = atBottom() }
    this.onSubmit = () => { this.following = true }

    window.addEventListener("scroll", this.onScroll, {passive: true})
    this.el.addEventListener("submit", this.onSubmit)
    this.focusQuestionBox()
    this.toNewest()
  },

  // The page's height just before an update, to tell whether the update made
  // it taller. Taken here and not carried over from the last update: a
  // rotated phone or a resized window changes the height in between.
  beforeUpdate() {
    this.height = pageHeight()
  },

  // An update does not scroll the page, so `following` still says where the
  // reader was before it. Most updates add nothing (each keystroke in the
  // question box is one), and those leave the page where it is.
  updated() {
    const grew = pageHeight() > this.height
    this.focusQuestionBox()

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

  // The form is taken off the page while the conversation works, so the box
  // that comes back is a new element with no focus. Focus it once, when it
  // appears, without letting the browser scroll to it.
  focusQuestionBox() {
    const box = this.el.querySelector("#question-form input[type=text]:not([disabled])")
    if (box && !this.hadBox && finePointer.matches) box.focus({preventScroll: true})
    this.hadBox = Boolean(box)
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
