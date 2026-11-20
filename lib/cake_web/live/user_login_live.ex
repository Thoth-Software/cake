defmodule CakeWeb.UserLoginLive do
  use CakeWeb, :live_view

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Log in to account
        <:subtitle>
          Don't have an account?
          <.link navigate={~p"/users/register"} class="link link-primary">Sign up</.link>
          for an account now.
        </:subtitle>
      </.header>

      <div class="card card-border bg-base-100">
        <div class="card-body">
          <.form for={@form} id="login_form" action={~p"/users/log_in"} phx-update="ignore">
            <.input
              field={@form[:username]}
              type="text"
              label="Username"
              autocomplete="username"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              required
            />

            <div class="flex flex-wrap items-center justify-between gap-x-6">
              <.input field={@form[:remember_me]} type="checkbox" label="Keep me logged in" />
              <.link href={~p"/users/reset_password"} class="link link-hover mb-2 text-sm">
                Forgot your password?
              </.link>
            </div>

            <.button phx-disable-with="Logging in..." class="btn btn-primary mt-2 w-full">
              Log in <span aria-hidden="true">→</span>
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    username = Phoenix.Flash.get(socket.assigns.flash, :username)
    form = to_form(%{"username" => username}, as: "user")
    {:ok, assign(socket, page_title: "Log in", form: form), temporary_assigns: [form: form]}
  end
end
