defmodule CakeWeb.PageController do
  use CakeWeb, :controller

  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    if conn.assigns.current_user do
      redirect(conn, to: ~p"/chat")
    else
      render(conn, :home)
    end
  end
end
