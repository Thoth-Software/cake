defmodule Caque.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CaqueWeb.Telemetry,
      Caque.Repo,
      {DNSCluster, query: Application.get_env(:caque, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Caque.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Caque.Finch},
      # Start a worker by calling: Caque.Worker.start_link(arg)
      # {Caque.Worker, arg},
      # Start to serve requests, typically the last entry
      CaqueWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Caque.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CaqueWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
