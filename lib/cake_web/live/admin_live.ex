defmodule CakeWeb.AdminLive do
  @moduledoc """
  The landing page of the admin area, at `/admin`.

  It is minimal on purpose: a heading, so that the guard has a real page to
  protect (`CakeWeb.UserAuth.require_admin/2` on the request,
  `on_mount :ensure_admin` on the mount). The admin panel fills it (#376).
  """

  use CakeWeb, :live_view

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>Admin</.header>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Admin")}
  end
end
