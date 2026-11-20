# UI reference screenshots

What the app looks like, for putting a new screen beside. The conventions these pictures show are written down in `.claude/rules/front-end.md`, "Look and feel"; the pictures are the result, not the rule.

Each state is captured four times, as `<state>-<width>-<theme>.png`:

- **width**: `desktop` (1280 × 800) or `phone` (390 × 844), at twice the pixel density. The rule a screen has to meet is stricter than the phone shots: nothing scrolls sideways at 360px. Check that width in a browser too;
- **theme**: `light` (daisyUI's Fantasy) or `dark` (its Dracula).

| State | What it shows |
|---|---|
| `home` | The home page for a visitor: the product name, one sentence, the log-in button. |
| `shell-member` | The app shell for a member, on the search screen before any search: the top bar's links, the theme toggle, the user menu, a `header/1` and a form with its one primary button. |
| `shell-member-menu` | Phone width only: the menu the top bar's links collapse into, open. |
| `shell-admin` | The app shell for an admin: the same, with the Admin link. |
| `search-working` | `working/1`: a search in flight. |
| `search-empty` | `empty_state/1`: a search that finished and found nothing. |
| `search-error` | `notice/1` of kind `:error`: a search that failed. |
| `search-results` | Content results as cards, with page chips. |

## How they were taken

In a real browser (headless Chromium, driven by Playwright) against the dev server, signed in as a member and as an admin made with `Cake.Accounts.create_user/1`.

The search states need an index and a query embedding, and the session that took them had no provider key. So the embeddings client was pointed at a local stand-in that answers every request with one fixed vector, waits when asked to, and fails when asked to; the search backend was a real OpenSearch node. `search-working`, `search-empty` and `search-error` were taken against an empty index. For `search-results`, two small PDFs written for the purpose were uploaded through the upload screen and ingested by the real pipeline. Nothing in the pictures comes from a real document or a real provider.

## Keeping them current

Retake the ones a change affects when the shell, a shared component or a theme changes. A screenshot that no longer matches the app is worse than none.
