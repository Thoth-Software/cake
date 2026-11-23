defmodule CakeWeb.PageController do
  @moduledoc """
  Serves `/`. A visitor gets the home page: the product's name, a line on
  what it does and a link to the log-in page. A logged-in user is
  redirected to `/chat`.
  """

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
