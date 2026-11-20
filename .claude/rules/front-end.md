---
paths:
  - "assets/**"
  - "lib/cake_web/components/**"
  - "lib/cake_web/live/**"
  - "lib/cake_web/controllers/**/*.heex"
  - "lib/cake_web.ex"
---

# Front end

Auto-loaded when working on `assets/`, the components and layouts, a LiveView or a controller template. README "Components, Layouts and Assets" says what each piece is; this says how to work on them.

## The rules

- **Generator first.** The kit is `mix phx.new` output, and a new screen starts from `mix phx.gen.live`, `mix phx.gen.html` or `mix phx.gen.auth` output: run the generator of the Phoenix version `mix.lock` holds (`mix archive.install hex phx_new <that version>`), commit what it wrote unedited, then hand-edit in later commits, so every edit reads as a diff against generator output. A file that cannot sit raw at its real path without breaking a gate goes in a staging directory for that one commit.
- **daisyUI classes over ad-hoc utilities.** Reach for a component class (`btn`, `input`, `alert`, `navbar`, `card`, `table`, `menu`) and a semantic colour (`text-base-content`, `bg-base-100`, `btn-primary`, `text-error`) before spelling one out of Tailwind utilities. Utilities are for layout: spacing, flex, grid, width.
- **No hard-coded palette colours.** `bg-white`, `text-zinc-900` and their kin are right in one theme and unreadable in the other. A colour comes from the theme.
- **No Node.** `mix assets.build` and `mix assets.deploy` run the standalone Tailwind and esbuild binaries and nothing else: no `package.json`, no `node_modules`, no npm package. A JavaScript library is vendored as a file under `assets/vendor/`; a Tailwind plugin is a Mix dependency or a vendored file.
- **Every template calls `Layouts.app` and hands it the user.** A LiveView's `render/1` wraps its content in `<Layouts.app flash={@flash} current_user={@current_user}>`, and so does a controller template (`page_html/home.html.heex`). `use CakeWeb, :live_view` names no layout, so a template that forgets has no top bar and shows no flash; `current_user` is a required attribute, so one that forgets the user does not compile. The error pages are the one exception: `CakeWeb.ErrorHTML` renders inside the root layout and outside the shell, because an error can happen before the request has a user or a flash.
- **Every LiveView sets `page_title`.** The root layout titles a page "<page> · Cake" when `page_title` is assigned and "Cake" when it is not, and it adds the suffix only when the first page it rendered had a title. A LiveView without one would lose the suffix for every page live-navigated to after it. `CakeWeb.ShellTest` lists every page with its title: add a new page there.
- **A new page goes in the shell's links in one place**, `nav_links/1` in `layouts.ex`, and in `CakeWeb.LayoutsTest`, `LayoutsPropertyTest` and `ShellTest`, which pin who sees which link. The links are rendered twice (`#main-nav` for wide screens, `#mobile-nav` for the menu they collapse into), so a link has no `id`: a test selects it by its container and its `href`.
- **Nothing new calls `CakeWeb.TransitionalComponents`.** It holds the 1.7 `simple_form/1` and `error/1` for the screens not yet migrated. A migrated screen uses `<.form>` and `<.input>`; when the last caller of a function goes, so does the function, and with the last function the module and its import in `lib/cake_web.ex`.
- **LiveView is 1.0.** The kit is written for `phoenix_live_view ~> 1.2`. What needs the newer one is left out: colocated hooks (the `phoenix-colocated/cake` import in `app.js`), colocated CSS (its import and `@source` in `app.css`) and the `:phoenix_live_view` compiler in `mix.exs`. A hook goes in `assets/js/` and is passed to `LiveSocket` by hand. Bring the three back together when LiveView is bumped.

## Traps

- **`<.button class="...">` replaces the classes, it does not add to them.** The 1.8 `button/1` uses its own `btn btn-primary btn-soft` only when the caller passes no `class`. A caller that passes one writes the whole list: `class="btn btn-primary w-full"`.
- **The suite cannot see a style.** The LiveView tests assert on text and structure, so a page that has lost its styling passes them. After a change to a component, a layout or `app.css`, build the assets, load the page in a browser and look at it in both themes (the navbar's toggle, or `data-theme="dark"` on `<html>`).
- **The dev container does not build assets.** In Docker the watchers are off (`config/dev.exs`) and the repo is bind-mounted, so the container serves whatever `priv/static/assets/` the host built. Run `mix assets.build` on the host after pulling a change to `assets/`.
- **A form with `phx-submit` needs an `id` and a `phx-change`,** or credo fails it (`LiveViewFormCanBeRehydrated`): without them LiveView cannot put back what was typed after a reconnect. A form that has no change event and nothing worth recovering says so with `phx-auto-recover="ignore"`, as the search box does.
- **The inline theme script.** `root.html.heex` sets `data-theme` from an inline `<script>` before first paint. A Content-Security-Policy without `'unsafe-inline'` blocks it (#213).

## Where the files come from, and how to update them

| What | From | To update |
|---|---|---|
| `core_components.ex`, `layouts.ex`, `layouts/root.html.heex`, `assets/css/app.css`, `assets/js/app.js`, `assets/vendor/heroicons.js`, `assets/vendor/topbar.js`, `assets/tsconfig.json`, the `config :esbuild` and `config :tailwind` blocks | `mix phx.new cake --no-install` with `phx_new` 1.8.16 (#374) | Generate a scratch app outside the repo with the `phx_new` of the new Phoenix version, diff each file against the one here, and carry the generator's changes across by hand. The edits made here are `@spec`s, `header/1`'s `class` attribute, the root layout's title, `app/1` (the generator's placeholder navbar is replaced by Cake's shell, #375), the theme buttons' `aria-label`s, the flash's position (the bottom corner, `toast-bottom`: at the top it covers the account menu and the menu that opens under it), the flash wording the 1.7 `flash_group/1` had (the "Success!" and "Error!" titles, and the server-error notice's text; `CakeWeb.LayoutsTest` pins both), and the LiveView 1.2 features left out. |
| daisyUI | The Mix dependency `:daisyui` in `mix.exs`: the GitHub repository at a tag, sparse-checked-out to `packages/bundle`, not compiled. `app.css` loads it with `@plugin "daisyui/packages/bundle/daisyui"`. | Change the tag, `mix deps.get`, `mix assets.build`, look at the pages in both themes. |
| The two themes | Two `daisyui-theme` blocks in `app.css`, named `light` and `dark`: the names the theme toggle, the inline theme script and the `dark:` variant use. Their values are copied from two of daisyUI's own themes as the bundle in `deps/daisyui` defines them: `light` is Fantasy, `dark` is Dracula (#375). | To change a theme, replace a block's values with another daisyUI theme's (the `themes` object in `deps/daisyui/packages/bundle/daisyui.js`, or https://daisyui.com/theme-generator/) and keep the name. After moving the daisyUI tag, compare the two blocks with the bundle's `fantasy` and `dracula`. |
| heroicons | The Mix dependency `:heroicons`, the same way. `assets/vendor/heroicons.js` turns its SVGs into `hero-*` classes. | Change the tag, `mix deps.get`, `mix assets.build`. |
| Tailwind and esbuild | Standalone binaries the `:tailwind` and `:esbuild` Hex packages download into `_build/` (`mix assets.setup`), at the `version:` each has in `config/config.exs`. | Change `version:`, `mix assets.setup`, `mix assets.build`. Tailwind is configured in `app.css`; there is no `tailwind.config.js`. |

`:daisyui` and `:heroicons` are Git dependencies. `mix hex.audit` and `mix deps.audit` read Hex packages, so neither covers them: read the release notes when moving a tag.
