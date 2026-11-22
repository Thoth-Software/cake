defmodule CakeWeb.Admin.UserLive.Show do
  @moduledoc """
  One login's page in the admin panel, at `/admin/users/:id`: its username,
  email, role, whether its email is confirmed, and created date, with the
  way to its form and to setting its password. A login that no longer exists
  sends the admin back to the list, saying so.

  A login cannot log in until its email is confirmed (#377). From here the
  admin confirms it by hand, or takes the confirmation back
  (`Cake.Accounts.set_user_confirmed/3`), behind a confirmation. Nobody
  takes their own confirmation back: the admin's own page has no button for
  it, and a request for it is refused with a notice. Taking a confirmation
  back stops the next log-in; it does not end the sessions the login
  already has (#401).
  """

  use CakeWeb, :live_view

  alias Cake.Accounts
  alias Cake.Accounts.User

  @gone "That login no longer exists."

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

      <.notice :if={@refusal} id="login-refusal" kind={:error}>{@refusal}</.notice>

      <div id="login">
        <.list>
          <:item title="Username"><span class="wrap-anywhere">{@user.username}</span></:item>
          <:item title="Email"><span class="wrap-anywhere">{@user.email}</span></:item>
          <:item title="Role">{@user.role}</:item>
          <:item title="Confirmed">{if @user.confirmed_at, do: "yes", else: "no"}</:item>
          <:item title="Created">{created_on(@user)}</:item>
        </.list>
      </div>

      <div class="flex flex-wrap gap-2">
        <button
          :if={!@user.confirmed_at}
          id="confirm-login"
          type="button"
          class="btn btn-outline"
          phx-click="confirm"
        >
          Confirm email
        </button>
        <button
          :if={@user.confirmed_at && @user.id != @current_user.id}
          id="unconfirm-login"
          type="button"
          class="btn btn-outline"
          phx-click="unconfirm"
          data-confirm={"Take back #{@user.username}'s confirmation? They will not be able to log in until it is confirmed again."}
        >
          Take confirmation back
        </button>
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
         |> assign(:refusal, nil)
         |> assign(:user, user)}

      # Deleted since the link here was rendered.
      nil ->
        {:ok,
         socket
         |> put_flash(:error, @gone)
         |> push_navigate(to: ~p"/admin/users")}
    end
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("confirm", _params, socket), do: set_confirmed(socket, true)
  def handle_event("unconfirm", _params, socket), do: set_confirmed(socket, false)
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp set_confirmed(socket, confirmed?) do
    case Accounts.set_user_confirmed(socket.assigns.current_user, socket.assigns.user, confirmed?) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:refusal, nil)
         |> put_flash(
           :info,
           if(confirmed?, do: "Email confirmed", else: "Confirmation taken back")
         )}

      {:error, :own_account} ->
        {:noreply,
         socket
         |> clear_flash()
         |> assign(:refusal, "You cannot take back your own confirmation.")}
    end
  rescue
    # The login was deleted while its page was open.
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:error, @gone)
       |> push_navigate(to: ~p"/admin/users")}
  end

  defp created_on(%User{inserted_at: inserted_at}), do: Calendar.strftime(inserted_at, "%Y-%m-%d")
end
