# #364 spike, question 1: can a BEAM node reach the search node over Fly's
# private network? Usage: elixir probe.exs URL [URL ...]
Mix.install([{:snap, "0.12.2"}, {:finch, "0.24.0"}, {:jason, "1.4.5"}])

defmodule Probe.V4 do
  use Snap.Cluster, otp_app: :probe
end

defmodule Probe.V6 do
  use Snap.Cluster, otp_app: :probe
end

for url <- System.argv() do
  host = URI.parse(url).host
  IO.puts("\n== #{url}")
  IO.puts("getaddr inet : #{inspect(:inet.getaddr(to_charlist(host), :inet))}")
  IO.puts("getaddr inet6: #{inspect(:inet.getaddr(to_charlist(host), :inet6))}")

  for {cluster, conn_opts} <- [
        {Probe.V4, []},
        {Probe.V6, [transport_opts: [inet6: true]]}
      ] do
    Application.put_env(:probe, cluster,
      url: url,
      http_client_adapter: {Snap.HTTPClient.Adapters.Finch, conn_opts: conn_opts}
    )

    {:ok, pid} = cluster.start_link([])

    result =
      case Snap.get(cluster, "/_cluster/health") do
        {:ok, %{"status" => status, "cluster_name" => name}} -> "OK status=#{status} cluster=#{name}"
        {:ok, other} -> "OK #{inspect(other)}"
        {:error, error} -> "ERROR #{inspect(error)}"
      end

    IO.puts("snap+finch conn_opts=#{inspect(conn_opts)}: #{result}")
    Supervisor.stop(pid)
  end
end
