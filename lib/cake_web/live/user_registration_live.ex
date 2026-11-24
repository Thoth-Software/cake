defmodule CakeWeb.UserRegistrationLive do
  @moduledoc """
  The registration page, at `/users/register`: a username, an email and a
  password. `Cake.Accounts.register_user/1` stores an unconfirmed member;
  the page then mails the confirmation link and redirects to the log-in
  page. It logs nobody in, since log-in waits on the confirmed email. A
  refused registration shows its errors on the form.

  The delivery (`Cake.Accounts.deliver_user_confirmation_instructions/2`)
  is hard-matched on `{:ok, _}` after the user row is inserted, so a
  delivery that answered anything else would crash the LiveView with the
  user stored and no flash or redirect for the visitor. The adapter
  `config/config.exs` sets, `Swoosh.Adapters.Local`, answers only
  `{:ok, _}`, so the match cannot fail today. In a release that adapter's
  store is switched off (`config :swoosh, local: false` in
  `config/prod.exs`), and a delivery is expected to exit instead, with the
  same result (#367).
  """

  use CakeWeb, :live_view

  alias Cake.Accounts
  alias Cake.Accounts.User

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Register for an account
        <:subtitle>
          Already registered?
          <.link navigate={~p"/users/log_in"} class="link link-primary">Log in</.link>
          to your account now.
        </:subtitle>
      </.header>

      <.notice :if={@check_errors} id="registration-errors" kind={:error}>
        Oops, something went wrong! Please check the errors below.
      </.notice>

      <div class="card card-border bg-base-100">
        <div class="card-body">
          <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
            <.input
              field={@form[:username]}
              type="text"
              label="Username"
              autocomplete="username"
              required
            />
            <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              required
            />

            <.button phx-disable-with="Creating account..." class="btn btn-primary mt-2 w-full">
              Create an account
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{})

    socket =
      socket
      |> assign(page_title: "Register", check_errors: false)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      # Log-in waits on the email being confirmed, so registering logs
      # nobody in: it sends the link and says where to go next.
      {:ok, user} ->
        # A hard match, left as it is until there is a real mailer (#367):
        # the Local Swoosh adapter answers only {:ok, _}. Any other answer
        # would crash here with the user row already stored (see the
        # moduledoc).
        {:ok, _} =
          Accounts.deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))

        info =
          "Account created. We sent a link to #{user.email}: follow it to confirm your email, then log in."

        {:noreply, socket |> put_flash(:info, info) |> redirect(to: ~p"/users/log_in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end
end
