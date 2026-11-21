defmodule CakeWeb.Admin.UserLive.Index do
  @moduledoc """
  The admin panel's list of logins, at `/admin/users`: each user's username,
  role and created date, with the way to a login's own page, to its form,
  to a new one, and the button that deletes it.

  On a phone the table keeps the username, the role and Delete, and drops
  the rest (the created date, the email, the Edit shortcut) so that it does
  not scroll sideways: the username leads to the login's own page, which has
  them.

  Deleting goes through `Cake.Accounts.delete_user/1`, so the last admin
  cannot be deleted, and an admin cannot delete their own login: their row
  has no button, and a request for it is refused. A refusal is shown as a
  notice above the list, and so is a login that someone else deleted while
  this page still showed it. A deleted user's sessions go with them, and their
  open pages are sent to the log-in page
  (`CakeWeb.UserAuth.end_live_sessions/1`).
  """

  use CakeWeb, :live_view

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias CakeWeb.UserAuth

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} width={:wide}>
      <.header>
        Logins
        <:subtitle>Who can log in, and who is an admin.</:subtitle>
        <:actions>
          <.button id="new-login" variant="primary" navigate={~p"/admin/users/new"}>
            <.icon name="hero-plus" class="size-5" /> New login
          </.button>
        </:actions>
      </.header>

      <.notice :if={@refusal} id="users-refusal" kind={:error}>{@refusal}</.notice>

      <.table id="users" rows={@streams.users}>
        <:col :let={{_id, user}} label="Username">
          <.link navigate={~p"/admin/users/#{user}"} class="link link-hover wrap-anywhere">
            {user.username}
          </.link>
        </:col>
        <:col :let={{_id, user}} :if={@show_email?} label="Email" class="hidden lg:table-cell">
          <span class="wrap-anywhere">{user.email}</span>
        </:col>
        <:col :let={{_id, user}} label="Role">
          <span class={["badge badge-soft", role_badge(user.role)]}>{user.role}</span>
        </:col>
        <:col :let={{_id, user}} label="Created" class="hidden sm:table-cell">
          <span class="whitespace-nowrap">{created_on(user)}</span>
        </:col>
        <:action :let={{_id, user}}>
          <.link
            id={"edit-#{user.id}"}
            navigate={~p"/admin/users/#{user}/edit"}
            class="btn btn-ghost btn-sm hidden sm:inline-flex"
          >
            Edit
          </.link>
        </:action>
        <:action :let={{_id, user}}>
          <button
            :if={user.id != @current_user.id}
            id={"delete-#{user.id}"}
            type="button"
            class="btn btn-error btn-sm"
            phx-click={JS.push("delete", value: %{id: user.id})}
            data-confirm={"Delete the login #{user.username}? This cannot be undone."}
          >
            Delete
          </button>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Logins")
     |> assign(:refusal, nil)
     |> list_users()}
  end

  # The whole list, afresh. The Email column depends on every row, and a row
  # of a stream is rendered once, so when the list changes it is read and
  # rendered again rather than patched.
  defp list_users(socket) do
    users = Accounts.list_users()

    socket
    |> assign(:show_email?, Enum.any?(users, & &1.email))
    |> stream(:users, users, reset: true)
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("delete", %{"id" => id}, socket) do
    case delete(Accounts.get_user(id), socket.assigns.current_user) do
      {:ok, %User{} = deleted} ->
        :ok = UserAuth.end_live_sessions(deleted)

        {:noreply,
         socket
         |> assign(:refusal, nil)
         |> put_flash(:info, "Login deleted")
         |> list_users()}

      {:error, :gone} ->
        {:noreply, socket |> refuse("That login no longer exists.") |> list_users()}

      {:error, :own_login} ->
        {:noreply, refuse(socket, "You cannot delete your own login.")}

      {:error, :last_admin} ->
        {:noreply, refuse(socket, "The last admin cannot be deleted.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A refusal replaces the message of whatever was done before it.
  defp refuse(socket, message) do
    socket |> clear_flash() |> assign(:refusal, message)
  end

  # The context knows the last-admin rule; who is asking is known only here.
  # A login can be deleted by someone else while this page still shows it:
  # before the request (no such user) or during it (the context raises).
  defp delete(nil, %User{}), do: {:error, :gone}
  defp delete(%User{id: id}, %User{id: id}), do: {:error, :own_login}

  defp delete(%User{} = user, %User{}) do
    Accounts.delete_user(user)
  rescue
    Ecto.NoResultsError -> {:error, :gone}
  end

  defp role_badge(:admin), do: "badge-primary"
  defp role_badge(:member), do: "badge-ghost"

  defp created_on(%User{inserted_at: inserted_at}), do: Calendar.strftime(inserted_at, "%Y-%m-%d")
end
