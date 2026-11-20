defmodule CakeWeb.UserResetPasswordLive do
  use CakeWeb, :live_view

  alias Cake.Accounts

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>Reset Password</.header>

      <div class="card card-border bg-base-100">
        <div class="card-body">
          <.form
            for={@form}
            id="reset_password_form"
            phx-submit="reset_password"
            phx-change="validate"
          >
            <.notice :if={@form.errors != []} id="reset-password-errors" kind={:error}>
              Oops, something went wrong! Please check the errors below.
            </.notice>

            <.input
              field={@form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              required
            />
            <.button phx-disable-with="Resetting..." class="btn btn-primary mt-2 w-full">
              Reset Password
            </.button>
          </.form>
        </div>
      </div>

      <p class="text-center text-sm">
        <.link href={~p"/users/register"} class="link link-hover">Register</.link>
        | <.link href={~p"/users/log_in"} class="link link-hover">Log in</.link>
      </p>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(params, _session, socket) do
    socket = socket |> assign(:page_title, "Reset password") |> assign_user_and_token(params)

    form_source =
      case socket.assigns do
        %{user: user} ->
          Accounts.change_user_password(user)

        _ ->
          %{}
      end

    {:ok, assign_form(socket, form_source), temporary_assigns: [form: nil]}
  end

  # Do not log in the user after reset password to avoid a
  # leaked token giving the user access to the account.
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully.")
         |> redirect(to: ~p"/users/log_in")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_password(socket.assigns.user, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_user_and_token(socket, %{"token" => token}) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      assign(socket, user: user)
    else
      socket
      |> put_flash(:error, "Reset password link is invalid or it has expired.")
      |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, %{} = source) do
    assign(socket, :form, to_form(source, as: "user"))
  end
end
