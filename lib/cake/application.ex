defmodule Cake.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary, top_level?: true, deps: [Cake, CakeWeb, Cake.Search]
  use Application

  @impl Application
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [
      CakeWeb.Telemetry,
      Cake.Repo,
      {Oban, Application.fetch_env!(:cake, Oban)},
      {DNSCluster, query: Application.get_env(:cake, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cake.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Cake.Finch},
      {Cake.Search.Deployment, name: Cake.Search.Deployment},
      # One-shot: creates the configured search collections once the cluster
      # above is up (children start in order), then exits. A Task child is
      # :temporary, so a failure (an unreachable node) is logged by the
      # supervisor and never restarted or counted against the app.
      Supervisor.child_spec({Task, &Cake.Search.Deployment.create_configured_collections/0},
        id: :search_collections_bootstrap
      ),
      {Task.Supervisor, name: Cake.TaskSupervisor},
      {DynamicSupervisor, name: Cake.ConversationSupervisor, strategy: :one_for_one},
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
  @spec config_change(keyword(), keyword(), [atom()]) :: :ok
  def config_change(changed, _new, removed) do
    CakeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
