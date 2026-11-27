defmodule CakeWeb.UserSettingsLive do
  @moduledoc """
  The account settings page, at `/users/settings`, for a logged-in user. It
  shows the username, with no field to change it, and two forms.

  The email form (new email, current password) does not change the email:
  once `Cake.Accounts.apply_user_email/3` accepts it, a link is mailed to
  the new address. The link opens this LiveView at
  `/users/settings/confirm_email/:token`, where
  `Cake.Accounts.update_user_email/2` changes the email and marks it
  confirmed, or refuses the token.

  The password form (new password twice, current password) calls
  `Cake.Accounts.update_user_password/3`. A change deletes the user's
  sessions, this one included, so the browser then posts the form to
  `CakeWeb.UserSessionController` with `_action=password_updated`, which
  logs the user in again and returns them here.

  The user can be deleted while the page is open. A form finds them gone
  when it reaches the database: the password form whenever it is
  submitted, the email form once the new email and the current password
  are accepted (one it refuses shows its error, as for anyone). The page
  then calls `CakeWeb.UserAuth.end_live_sessions/1`: this page and every
  other the user has open go to the log-in page, told that the session has
  ended. That is what the admin panel does when it deletes a login; a
  deletion from anywhere else has told nobody. The link mailed for an email
  change,
  opened as its user is deleted, is refused as a token it does not accept
  is.
  """

  use CakeWeb, :live_view

  alias Cake.Accounts
  alias CakeWeb.UserAuth

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Account settings
        <:subtitle>
          <span id="settings-subtitle">
            Manage your account email address and password settings
          </span>
        </:subtitle>
      </.header>

      <%!-- The username is shown and has no field: this page does not change
      one (an admin's action, #376). --%>
      <.list>
        <:item title="Username">
          <span id="settings-username" class="wrap-anywhere">{@current_user.username}</span>
        </:item>
      </.list>

      <section class="card card-border bg-base-100">
        <div class="card-body">
          <h2 class="card-title">Email</h2>
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              required
            />
            <.input
              field={@email_form[:current_password]}
              name="current_password"
              id="current_password_for_email"
              type="password"
              label="Current password"
              value={@email_form_current_password}
              autocomplete="current-password"
              required
            />
            <.button phx-disable-with="Changing..." class="btn btn-outline mt-2">
              Change email
            </.button>
          </.form>
        </div>
      </section>

      <section class="card card-border bg-base-100">
        <div class="card-body">
          <h2 class="card-title">Password</h2>
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/log_in?_action=password_updated"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
          >
            <input
              name={@password_form[:username].name}
              type="hidden"
              id="hidden_user_username"
              value={@current_username}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
            />
            <.input
              field={@password_form[:current_password]}
              name="current_password"
              type="password"
              label="Current password"
              id="current_password_for_password"
              value={@current_password}
              autocomplete="current-password"
              required
            />
            <.button phx-disable-with="Changing..." class="btn btn-primary mt-2">
              Change password
            </.button>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_user, token) do
        :ok ->
          put_flash(socket, :info, "Email changed successfully.")

        :error ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    email_changeset = Accounts.change_user_email(user)
    password_changeset = Accounts.change_user_password(user)

    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign(:current_password, nil)
      |> assign(:email_form_current_password, nil)
      |> assign(:current_username, user.username)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.current_user
      |> Accounts.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form, email_form_current_password: password)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    case Accounts.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        {:noreply, mail_email_change_link(socket, applied_user)}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.current_user
      |> Accounts.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form, current_password: password)}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    case Accounts.update_user_password(user, password, user_params) do
      {:ok, user} ->
        password_form =
          user
          |> Accounts.change_user_password(user_params)
          |> to_form()

        {:noreply, assign(socket, trigger_submit: true, password_form: password_form)}

      {:error, :gone} ->
        {:noreply, end_sessions(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end

  defp mail_email_change_link(socket, applied_user) do
    delivery =
      Accounts.deliver_user_update_email_instructions(
        applied_user,
        socket.assigns.current_user.email,
        &url(~p"/users/settings/confirm_email/#{&1}")
      )

    case delivery do
      {:error, :gone} ->
        end_sessions(socket)

      # Mailed or not: the page says the same, as it always has.
      _mailed_or_not ->
        info = "A link to confirm your email change has been sent to the new address."
        socket |> put_flash(:info, info) |> assign(email_form_current_password: nil)
    end
  end

  # The user was deleted while this page was open. An admin who deletes a
  # login from the panel sends the login's open pages away; a deletion from
  # anywhere else does not. So the page asks for the same itself: it hears
  # it with the user's other open pages, and each goes to the log-in page,
  # told that its session has ended.
  defp end_sessions(socket) do
    :ok = UserAuth.end_live_sessions(socket.assigns.current_user)
    socket
  end
end
