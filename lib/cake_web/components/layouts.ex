defmodule CakeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CakeWeb, :html

  alias Cake.Accounts.User

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app shell around a page: the top bar, the page and the flash
  messages.

  The top bar shows the product name, the links the user may follow, the
  theme toggle and either the user menu or the links to log in and register.
  The links are rendered twice, in `#main-nav` for wide screens and in
  `#mobile-nav`, a menu they collapse into on narrow ones.

  Every template calls it and passes the user, `nil` for a visitor:

      <Layouts.app flash={@flash} current_user={@current_user}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :any,
    required: true,
    doc: "the signed-in `Cake.Accounts.User`, or `nil` for a visitor"

  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    assigns = assign(assigns, :nav_links, nav_links(assigns.current_user))

    ~H"""
    <header class="navbar border-b border-base-300 bg-base-100 px-2 sm:px-6 lg:px-8">
      <div class="flex flex-none items-center">
        <div :if={@nav_links != []} class="dropdown lg:hidden">
          <div tabindex="0" role="button" class="btn btn-ghost btn-square" aria-label="Menu">
            <.icon name="hero-bars-3" class="size-5" />
          </div>
          <ul
            id="mobile-nav"
            tabindex="-1"
            class="menu dropdown-content z-20 mt-2 w-52 rounded-box bg-base-100 p-2 shadow"
          >
            <li :for={{label, path} <- @nav_links}>
              <.link navigate={path}>{label}</.link>
            </li>
          </ul>
        </div>
        <a id="brand" href={~p"/"} class="btn btn-ghost px-2 text-xl">Cake</a>
      </div>

      <nav id="main-nav" class="hidden flex-1 justify-center lg:flex">
        <ul class="menu menu-horizontal gap-1 px-1">
          <li :for={{label, path} <- @nav_links}>
            <.link navigate={path}>{label}</.link>
          </li>
        </ul>
      </nav>

      <div class="ml-auto flex flex-none items-center gap-2">
        <.theme_toggle />
        <div :if={@current_user} id="user-menu" class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost px-2">
            <.icon name="hero-user-circle" class="size-6 sm:hidden" />
            <span id="user-menu-username" class="sr-only sm:not-sr-only sm:max-w-[12rem] sm:truncate">
              {@current_user.username}
            </span>
            <.icon name="hero-chevron-down-micro" class="size-4" />
          </div>
          <ul
            tabindex="-1"
            class="menu dropdown-content z-20 mt-2 w-56 rounded-box bg-base-100 p-2 shadow"
          >
            <li class="menu-title truncate sm:hidden">{@current_user.username}</li>
            <li><.link href={~p"/users/settings"}>Change password</.link></li>
            <li><.link href={~p"/users/log_out"} method="delete">Log out</.link></li>
          </ul>
        </div>
        <div :if={!@current_user} id="guest-menu" class="flex items-center gap-1">
          <.link href={~p"/users/register"} class="btn btn-ghost btn-sm">Register</.link>
          <.link href={~p"/users/log_in"} class="btn btn-primary btn-sm">Log in</.link>
        </div>
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # The pages the top bar links to, as `{label, path}`, for the user given:
  # none for a visitor, and the admin area for an admin only.
  @spec nav_links(User.t() | nil) :: [{String.t(), String.t()}]
  defp nav_links(nil), do: []

  defp nav_links(%User{role: :admin}), do: member_links() ++ admin_links()
  defp nav_links(%User{}), do: member_links()

  defp member_links do
    [{"Chat", ~p"/chat"}, {"Upload", ~p"/upload"}, {"Search", ~p"/search"}]
  end

  defp admin_links, do: [{"Admin", ~p"/admin"}]

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} title={gettext("Success!")} flash={@flash} />
      <.flash kind={:error} title={gettext("Error!")} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
