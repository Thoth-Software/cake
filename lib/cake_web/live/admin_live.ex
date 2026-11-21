defmodule CakeWeb.AdminLive do
  @moduledoc """
  The landing page of the admin area, at `/admin`.

  It lists what an admin can manage, which today is one thing: the logins,
  at `/admin/users` (`CakeWeb.Admin.UserLive.Index`). The top bar's Admin
  link leads here, for admins only, and every page under `/admin` is behind
  the same guard (`CakeWeb.UserAuth.require_admin/2` on the request,
  `on_mount :ensure_admin` on the mount).
  """

  use CakeWeb, :live_view

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:admin}>
      <.header>
        Admin
        <:subtitle>What only an admin can do.</:subtitle>
      </.header>

      <div class="card card-border bg-base-100">
        <div class="card-body">
          <h2 class="card-title">Logins</h2>
          <p class="text-base-content/70">
            Create a login, change its username or role, set a new password for it, or remove it.
          </p>
          <div class="card-actions">
            <.button id="admin-logins" variant="primary" navigate={~p"/admin/users"}>
              Manage logins
            </.button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Admin")}
  end
end
