defmodule CakeWeb.ErrorHTML do
  @moduledoc """
  The error pages the endpoint renders for HTML requests: one page for
  every status, showing the status code, its standard message and a link
  home. It is rendered inside the root layout (`render_errors` in
  `config/config.exs`), so it has the stylesheet and the theme, and outside
  the app layout: an error can happen before the request has a user or a
  flash, and the shell needs both.
  """
  use CakeWeb, :html

  @doc """
  Renders the page for the status in `template`'s name, such as `"404.html"`.
  """
  @spec render(String.t(), map()) :: Phoenix.LiveView.Rendered.t()
  def render(template, _assigns) do
    assigns = %{
      status: template |> String.split(".") |> hd(),
      message: Phoenix.Controller.status_message_from_template(template)
    }

    ~H"""
    <main class="hero min-h-screen">
      <div class="hero-content text-center">
        <div class="max-w-md">
          <p id="error-status" class="text-6xl font-bold text-primary">{@status}</p>
          <h1 id="error-message" class="mt-4 text-2xl font-semibold">{@message}</h1>
          <a id="error-home" href={~p"/"} class="btn btn-primary mt-8">Back to Cake</a>
        </div>
      </div>
    </main>
    """
  end
end
