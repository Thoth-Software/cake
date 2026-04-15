defmodule Cake.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      CakeWeb.Telemetry,
      Cake.Repo,
      {Oban, Application.fetch_env!(:cake, Oban)},
      {DNSCluster, query: Application.get_env(:cake, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cake.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Cake.Finch},
      {Cake.Documents.Cluster, name: Cake.Documents.Cluster},
      # Start a worker by calling: Cake.Worker.start_link(arg)
      # {Cake.Worker, arg},
      # Start to serve requests, typically the last entry
      CakeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, max_restarts: 5, name: Cake.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl Application
  def config_change(changed, _new, removed) do
    CakeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
