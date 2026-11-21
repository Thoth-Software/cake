defmodule CakeWeb.Admin.UserLive.Show do
  @moduledoc """
  One login's page in the admin panel, at `/admin/users/:id`: its username,
  role, created date and, when it has one, email, with the way to its form
  and to setting its password. A login that no longer exists sends the admin
  back to the list, saying so.
  """

  use CakeWeb, :live_view

  alias Cake.Accounts
  alias Cake.Accounts.User

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        <span class="wrap-anywhere">{@user.username}</span>
        <:actions>
          <.button
            id="edit-login"
            variant="primary"
            navigate={~p"/admin/users/#{@user}/edit?return_to=show"}
          >
            <.icon name="hero-pencil-square" class="size-5" /> Edit
          </.button>
        </:actions>
      </.header>

      <div id="login">
        <.list>
          <:item title="Username"><span class="wrap-anywhere">{@user.username}</span></:item>
          <:item title="Role">{@user.role}</:item>
          <:item title="Created">{created_on(@user)}</:item>
          <:item :if={@user.email} title="Email">
            <span class="wrap-anywhere">{@user.email}</span>
          </:item>
        </.list>
      </div>

      <div class="flex flex-wrap gap-2">
        <.link id="set-password" navigate={~p"/admin/users/#{@user}/password"} class="btn btn-outline">
          Set password
        </.link>
        <.link id="back-to-logins" navigate={~p"/admin/users"} class="btn btn-ghost">
          <.icon name="hero-arrow-left" class="size-5" /> All logins
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    case Accounts.get_user(id) do
      %User{} = user ->
        {:ok,
         socket
         |> assign(:page_title, user.username)
         |> assign(:user, user)}

      # Deleted since the link here was rendered.
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That login no longer exists.")
         |> push_navigate(to: ~p"/admin/users")}
    end
  end

  defp created_on(%User{inserted_at: inserted_at}), do: Calendar.strftime(inserted_at, "%Y-%m-%d")
end
