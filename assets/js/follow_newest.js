// Keeps the newest message of the chat in view as the conversation grows
// (CakeWeb.ChatLive, on #chat).
//
// The chat scrolls with the page, under a bar that sticks to the bottom of
// the screen. While the reader is at the bottom, each update scrolls the page
// back down to it. Scrolling up to read stops that, so an answer arriving
// does not pull the page away; scrolling back down, or sending a question,
// starts it again.

// How close to the bottom still counts as being there, in pixels.
const NEAR = 80

const atBottom = () =>
  window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - NEAR

const FollowNewest = {
  mounted() {
    this.following = true
    this.onScroll = () => { this.following = atBottom() }
    // The page gets shorter when an on-screen keyboard opens: stay on the
    // newest message if that is where the reader was.
    this.onResize = () => { if (this.following) this.toNewest() }
    this.onSubmit = () => { this.following = true }

    window.addEventListener("scroll", this.onScroll, {passive: true})
    window.addEventListener("resize", this.onResize)
    this.el.addEventListener("submit", this.onSubmit)
    this.toNewest()
  },

  // An update does not scroll the page, so `following` still says where the
  // reader was before it.
  updated() {
    if (this.following) this.toNewest()
  },

  destroyed() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
  },

  // Not a smooth scroll: its intermediate positions would read as the
  // reader scrolling up.
  toNewest() {
    window.scrollTo({top: document.documentElement.scrollHeight, behavior: "instant"})
  },
}

export default FollowNewest
