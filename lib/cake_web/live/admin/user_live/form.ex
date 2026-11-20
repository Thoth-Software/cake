defmodule CakeWeb.Admin.UserLive.Form do
  @moduledoc """
  The admin panel's forms for a login, one per live action:

    * `:new`, at `/admin/users/new`: a username, a password and a role
      (`Cake.Accounts.create_user/1`);
    * `:edit`, at `/admin/users/:id/edit`: the username and the role, and no
      password (`Cake.Accounts.update_user/2`);
    * `:password`, at `/admin/users/:id/password`: a new password and
      nothing else (`Cake.Accounts.reset_user_password/2`). It ends every
      session the user has, and sends their open pages to the log-in page
      (`CakeWeb.UserAuth.end_live_sessions/1`), so the old password stops
      working everywhere at once.

  A refusal is an error on the field it is about: a taken username on the
  username, the demotion of the last admin on the role.

  A password is typed in and never comes back. The password field is always
  rendered empty, whatever was typed and whatever the outcome, so no
  response carries one; nothing typed goes into a URL; and the parameter is
  named `password`, which Phoenix filters out of the log.
  """

  use CakeWeb, :live_view

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias CakeWeb.UserAuth

  @roles [{"Member", "member"}, {"Admin", "admin"}]

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns = assign(assigns, :roles, @roles)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        {@page_title}
        <:subtitle>{subtitle(@live_action, @user)}</:subtitle>
      </.header>

      <.form
        :if={@live_action in [:new, :edit]}
        for={@form}
        id="user-form"
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:username]} type="text" label="Username" autocomplete="off" />
        <.input
          :if={@live_action == :new}
          field={@form[:password]}
          type="password"
          label="Password"
          value=""
          autocomplete="new-password"
        />
        <.input field={@form[:role]} type="select" label="Role" options={@roles} />
        <footer class="mt-4 flex flex-wrap gap-2">
          <.button phx-disable-with="Saving..." variant="primary">Save login</.button>
          <.link navigate={return_path(@return_to, @user)} class="btn btn-ghost">Cancel</.link>
        </footer>
      </.form>

      <.form
        :if={@live_action == :password}
        for={@form}
        id="password-form"
        phx-change="validate"
        phx-submit="save"
      >
        <.input
          field={@form[:password]}
          type="password"
          label="New password"
          value=""
          autocomplete="new-password"
        />
        <footer class="mt-4 flex flex-wrap gap-2">
          <.button phx-disable-with="Saving..." variant="primary">Set password</.button>
          <.link navigate={~p"/admin/users/#{@user}"} class="btn btn-ghost">Cancel</.link>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New login")
    |> assign(:user, %User{})
    |> assign_form(change(:new, %User{}, %{}))
  end

  defp apply_action(socket, action, %{"id" => id}) when action in [:edit, :password] do
    user = Accounts.get_user!(id)

    socket
    |> assign(:page_title, title(action))
    |> assign(:user, user)
    |> assign_form(change(action, user, %{}))
  end

  defp title(:edit), do: "Edit login"
  defp title(:password), do: "Set password"

  defp subtitle(:new, _user), do: "Someone who can log in. They can use the password at once."
  defp subtitle(:edit, user), do: "The username and role of #{user.username}."

  defp subtitle(:password, user),
    do: "For #{user.username}. Everywhere they are logged in, they are logged out."

  # The changeset each form tracks what is typed with.
  defp change(:new, user, params), do: Accounts.change_user_creation(user, params)
  defp change(:edit, user, params), do: Accounts.change_user(user, params)
  defp change(:password, user, params), do: Accounts.change_user_password(user, params)

  defp assign_form(socket, %Ecto.Changeset{} = changeset, opts \\ []) do
    assign(socket, :form, to_form(changeset, [as: :user] ++ opts))
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = change(socket.assigns.live_action, socket.assigns.user, user_params)
    {:noreply, assign_form(socket, changeset, action: :validate)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    save_user(socket, socket.assigns.live_action, user_params)
  end

  defp save_user(socket, :new, user_params) do
    case Accounts.create_user(user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Login created")
         |> push_navigate(to: return_path(socket.assigns.return_to, user))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_user(socket, :edit, user_params) do
    case Accounts.update_user(socket.assigns.user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Login updated")
         |> push_navigate(to: return_path(socket.assigns.return_to, user))}

      {:error, :last_admin} ->
        changeset =
          :edit
          |> change(socket.assigns.user, user_params)
          |> Ecto.Changeset.add_error(:role, "cannot be changed: this is the last admin")

        {:noreply, assign_form(socket, changeset, action: :validate)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_user(socket, :password, user_params) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, user} ->
        :ok = UserAuth.end_live_sessions(user)

        {:noreply,
         socket
         |> put_flash(:info, "Password set")
         |> push_navigate(to: ~p"/admin/users/#{user}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp return_path("index", _user), do: ~p"/admin/users"
  defp return_path("show", user), do: ~p"/admin/users/#{user}"
end
