defmodule CakeWeb.Admin.UserLive.Form do
  @moduledoc """
  The admin panel's forms for a login, one per live action:

    * `:new`, at `/admin/users/new`: a username, an email, a password and a
      role (`Cake.Accounts.create_user/1`). The login is confirmed from the
      start, so it can log in at once;
    * `:edit`, at `/admin/users/:id/edit`: the username, the email and the
      role, and no password (`Cake.Accounts.update_user/2`). A changed email
      leaves the login confirmed or not, as it was;
    * `:password`, at `/admin/users/:id/password`: a new password and
      nothing else (`Cake.Accounts.reset_user_password/2`). It ends every
      session the user has, and sends their open pages to the log-in page
      (`CakeWeb.UserAuth.end_live_sessions/1`), so the old password stops
      working everywhere at once.

  A refusal is an error on the field it is about: a taken username on the
  username, a taken or missing email on the email, the demotion of the last
  admin, or of the last one whose email is confirmed, on the role.

  The edit form writes only what was changed on it. It sends every field
  every time, so a form opened a while ago would otherwise put back a
  username, an email or a role that someone else has changed since. A login deleted
  while its form is open is reported, and the admin is sent to the list.

  A password is typed in and never comes back. The password field is always
  rendered empty, whatever was typed and whatever the outcome, so no
  response carries one; nothing typed goes into a URL, a form submitted
  without LiveView included, since every form here says `method="post"`
  (a form for a stored record would otherwise say `put`, which a browser
  sends as GET); and the parameter is named `password`, which Phoenix
  filters out of the log.

  That filter does not reach a crash report, which prints the message a
  page was handling and everything it held. What this module can do about
  that, it does: the form held in the socket never carries the password
  (`assign_form/3` removes it), a field that is not text never reaches the
  template, and a save that raises is reported on the page and logged by
  its exception's name alone, without the message that caused it.

  It cannot do all of it. The message is the process's, not this module's:
  a crash anywhere else while a password-bearing event is being handled
  (in a hook, in the template, in LiveView itself) still prints the event.
  Closing that for every page is #399.
  """

  use CakeWeb, :live_view

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias CakeWeb.UserAuth

  require Logger

  @roles [{"Member", "member"}, {"Admin", "admin"}]
  @gone "That login no longer exists."

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
        method="post"
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:username]} type="text" label="Username" autocomplete="off" />
        <.input field={@form[:email]} type="email" label="Email" autocomplete="off" />
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
        method="post"
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
    action = socket.assigns.live_action

    case login(action, params) do
      %User{} = user ->
        {:ok,
         socket
         |> assign(:return_to, return_to(action, params["return_to"]))
         |> assign(:page_title, title(action))
         |> assign(:user, user)
         |> assign_form(change(action, user, %{}))}

      nil ->
        {:ok,
         socket
         |> put_flash(:error, @gone)
         |> push_navigate(to: ~p"/admin/users")}
    end
  end

  # The login a form is for: a new one, or the one the address names, which
  # may have been deleted since the link to this form was rendered.
  defp login(:new, _params), do: %User{}
  defp login(_action, %{"id" => id}), do: Accounts.get_user(id)

  # Only the edit form is opened from a login's own page.
  defp return_to(:edit, "show"), do: "show"
  defp return_to(_action, _), do: "index"

  defp title(:new), do: "New login"
  defp title(:edit), do: "Edit login"
  defp title(:password), do: "Set password"

  defp subtitle(:new, _user), do: "Someone who can log in. They can use the password at once."
  defp subtitle(:edit, user), do: "The username, email and role of #{user.username}."

  defp subtitle(:password, user),
    do: "For #{user.username}. Everywhere they are logged in, they are logged out."

  # The changeset each form tracks what is typed with.
  defp change(:new, user, params), do: Accounts.change_user_creation(user, params)
  defp change(:edit, user, params), do: Accounts.change_user(user, params)
  defp change(:password, user, params), do: Accounts.change_user_password(user, params)

  # The form the page holds never carries the password: not among the
  # changeset's changes, where only `inspect/1` would hide it, and not among
  # its params. The parameter stays, blank, so that the field still counts
  # as filled in and shows its errors, which the changeset keeps.
  defp assign_form(socket, %Ecto.Changeset{} = changeset, opts \\ []) do
    changeset =
      changeset
      |> Ecto.Changeset.delete_change(:password)
      |> Map.update!(:params, &blank_password/1)

    assign(socket, :form, to_form(changeset, [as: :user] ++ opts))
  end

  defp blank_password(%{"password" => _} = params), do: %{params | "password" => ""}
  defp blank_password(params), do: params

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate", %{"user" => user_params}, socket) do
    action = socket.assigns.live_action
    changeset = change(action, socket.assigns.user, text_fields(action, user_params))
    {:noreply, assign_form(socket, changeset, action: :validate)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    action = socket.assigns.live_action
    save_user(socket, action, text_fields(action, user_params))
  rescue
    # The login was deleted while its form was open.
    _gone in [Ecto.NoResultsError, Ecto.StaleEntryError] ->
      {:noreply,
       socket
       |> put_flash(:error, @gone)
       |> push_navigate(to: ~p"/admin/users")}

    # Anything else. The message being handled may hold a password, and a
    # crash would print it, so the page stays up and the log gets the
    # exception's name and where it was raised, not what it was raised with.
    error ->
      Logger.error(
        "#{inspect(__MODULE__)}: saving raised #{inspect(error.__struct__)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:noreply, put_flash(socket, :error, "That could not be saved.")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # What a form is allowed to send: its own fields, each as text, and for
  # each the `_unused_` key a browser sends beside a field nobody has touched
  # yet, by which the form leaves that field's errors unshown. A browser
  # sends nothing else. A hand-written request can send a map or a list in
  # a field's place, which a changeset refuses but a template cannot
  # render; such a field counts as not sent.
  @fields %{
    new: ~w(username email password role),
    edit: ~w(username email role),
    password: ~w(password)
  }

  defp text_fields(action, %{} = user_params) do
    fields = Map.fetch!(@fields, action)

    user_params
    |> Map.take(fields ++ Enum.map(fields, &("_unused_" <> &1)))
    |> Map.filter(fn {_field, value} -> is_binary(value) end)
  end

  defp text_fields(_action, _not_a_form), do: %{}

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
    case Accounts.update_user(socket.assigns.user, changed(socket.assigns.user, user_params)) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Login updated")
         |> push_navigate(to: return_path(socket.assigns.return_to, user))}

      {:error, last} when last in [:last_admin, :last_confirmed_admin] ->
        {:noreply, refuse_demotion(socket, user_params, last)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(:user, changeset.data) |> assign_form(changeset)}
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

  # A refused save shows the login as it is now, so that is what the next
  # save's changes are measured against.
  defp refuse_demotion(socket, user_params, last) do
    user = Accounts.get_user(socket.assigns.user.id) || socket.assigns.user

    changeset =
      :edit
      |> change(user, user_params)
      |> Ecto.Changeset.add_error(:role, demotion_refusal(last))

    socket |> assign(:user, user) |> assign_form(changeset, action: :validate)
  end

  # Why the role cannot be changed. An admin who is not confirmed cannot log
  # in, so the last confirmed one stays an admin as the last one does.
  defp demotion_refusal(:last_admin), do: "cannot be changed: this is the last admin"

  defp demotion_refusal(:last_confirmed_admin),
    do: "cannot be changed: no other admin has a confirmed email"

  # What the form changed: the fields that differ from the login as the
  # form last showed it (when it was opened, or after a refused save).
  defp changed(%User{} = user, user_params) do
    user_params
    |> Map.take(["username", "email", "role"])
    |> Map.reject(fn
      {"username", username} -> username == user.username
      {"email", email} -> email == user.email
      {"role", role} -> role == to_string(user.role)
    end)
  end

  defp return_path("index", _user), do: ~p"/admin/users"
  defp return_path("show", user), do: ~p"/admin/users/#{user}"
end
