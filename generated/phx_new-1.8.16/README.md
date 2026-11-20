# Raw `mix phx.new` output, Phoenix 1.8.16

Staging for #374 (box 1). These files are **exactly** what the generator
wrote, unedited, so that every later commit on the issue can be read as a
diff against generator output. Nothing here is compiled, formatted, linted
or built: the directory is outside `lib/`, `config/`, `test/`, `assets/` and
`priv/`.

Later boxes move each file to its real path (`git mv`) and edit it there.
When the issue is done this directory is gone.

## How it was made

`mix.lock` holds `phoenix 1.8.16`, so the generator is that version's:

    mix archive.install hex phx_new 1.8.16
    mix phx.new cake --no-install      # in a directory outside the repo

The app is named `cake`, so the modules already carry this repo's names
(`CakeWeb.CoreComponents`, `CakeWeb.Layouts`). All other options are the
generator's defaults.

## What is here

| File | From the scratch app |
|---|---|
| `assets/css/app.css` | Tailwind v4 is configured here, daisyUI's two themes included |
| `assets/js/app.js` | whole file |
| `assets/vendor/heroicons.js` | the Tailwind plugin for `hero-*` classes |
| `assets/vendor/topbar.js` | differs from the copy this repo has |
| `assets/tsconfig.json` | editor support for the LiveView JavaScript API |
| `lib/cake_web.ex` | whole file: `html_helpers/0` and `live_view/0` changed in 1.8 |
| `lib/cake_web/components/core_components.ex` | whole file |
| `lib/cake_web/components/layouts.ex` | whole file |
| `lib/cake_web/components/layouts/root.html.heex` | whole file |
| `config-excerpt.exs` | the `config :esbuild` and `config :tailwind` blocks, verbatim |
| `mix-excerpt.exs` | the compilers line, the deps and the aliases, verbatim |

## Where the kit differs from what #374 expected

The issue asks to confirm its list against the scratch app. Three things
are not as it lists them:

- **daisyUI is not vendored.** There is no `assets/vendor/daisyui.js` or
  `daisyui-theme.js`. The generator now takes daisyUI as a Mix dependency
  from GitHub (`mix-excerpt.exs`), as it takes heroicons, and `app.css`
  loads it with `@plugin "daisyui/packages/bundle/daisyui"`. It still
  needs no Node.
- **The kit targets `phoenix_live_view ~> 1.2`.** This repo is on 1.0.19.
  What depends on the newer LiveView is the colocated hooks import in
  `app.js`, the colocated CSS import and `@source` in `app.css`, and the
  `:phoenix_live_view` compiler in `mix.exs`. `core_components.ex` and
  `layouts.ex` use nothing newer than 1.0.
- **The built assets move.** The generator writes
  `priv/static/assets/css/app.css` and `priv/static/assets/js/app.js`,
  where this repo has `priv/static/assets/app.css` and `app.js`.
