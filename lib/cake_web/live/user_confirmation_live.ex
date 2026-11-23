defmodule CakeWeb.UserConfirmationLive do
  @moduledoc """
  The page a confirmation link opens, at `/users/confirm/:token`, open to
  visitors and logged-in users alike. Opening it confirms nothing: it shows
  one button, which passes the token to `Cake.Accounts.confirm_user/1`.
  Whether or not that confirms a user, the page then redirects to `/` and
  logs nobody in. A token it refuses gets an error flash, unless the
  visitor is logged in as a confirmed user, who gets no message.
  """

  use CakeWeb, :live_view

  alias Cake.Accounts

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{live_action: :edit} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Confirm account
        <:subtitle>Confirm the email address this link was sent to</:subtitle>
      </.header>

      <div class="card card-border bg-base-100">
        <div class="card-body">
          <%!-- The form carries only the link's token: nothing to recover. --%>
          <.form
            for={@form}
            id="confirmation_form"
            phx-submit="confirm_account"
            phx-auto-recover="ignore"
          >
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <.button phx-disable-with="Confirming..." class="btn btn-primary w-full">
              Confirm my account
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
  def mount(%{"token" => token}, _session, socket) do
    form = to_form(%{"token" => token}, as: "user")

    {:ok, assign(socket, page_title: "Confirm account", form: form),
     temporary_assigns: [form: nil]}
  end

  # Do not log in the user after confirmation to avoid a
  # leaked token giving the user access to the account.
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("confirm_account", %{"user" => %{"token" => token}}, socket) do
    case Accounts.confirm_user(token) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "User confirmed successfully.")
         |> redirect(to: ~p"/")}

      :error ->
        # If there is a current user and the account was already confirmed,
        # then odds are that the confirmation link was already visited, either
        # by some automation or by the user themselves, so we redirect without
        # a warning message.
        case socket.assigns do
          %{current_user: %{confirmed_at: confirmed_at}} when confirmed_at != nil ->
            {:noreply, redirect(socket, to: ~p"/")}

          %{} ->
            {:noreply,
             socket
             |> put_flash(:error, "User confirmation link is invalid or it has expired.")
             |> redirect(to: ~p"/")}
        end
    end
  end
end
