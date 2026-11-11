defmodule CakeLaws.MixProject do
  @moduledoc """
  LawSpec checks for Cake, kept apart from the main project (#323).

  LawSpec's BEAM targets require Erlang/OTP 29, and its generated runtime is
  not written to Cake's credo, boundary and warnings-as-errors gates, so the
  specification runs here, in its own CI job. This project compiles only the
  Cake modules its laws cover, listed in `@cake_sources`, and never the rest
  of Cake's application. A covered module that gains a dependency on another
  Cake module needs that module listed too: the compile fails until it is.
  """

  use Mix.Project

  # Mix takes a source outside the project only as an absolute path.
  @cake_root Path.expand("..", __DIR__)
  @cake_sources Enum.map(
                  [
                    "lib/cake/citable.ex",
                    "lib/cake/citations.ex",
                    "lib/cake/decomposition/result.ex",
                    "lib/cake/promptable.ex"
                  ],
                  &Path.join(@cake_root, &1)
                )

  def project do
    [
      app: :cake_laws,
      version: "0.1.0",
      elixir: "~> 1.20",
      erlc_paths: ["src"] ++ test_support(),
      elixirc_paths: ["lib"] ++ @cake_sources ++ test_support(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Cake's own dependencies are pinned to the exact versions in Cake's
  # mix.lock, so a covered module behaves here as it does in Cake. When Cake's
  # lock moves one of them, move it here too. StreamData is pinned to the
  # version LawSpec's Elixir target requires, not to Cake's.
  defp deps do
    [
      {:boundary, "== 0.10.4", runtime: false},
      {:ecto, "== 3.13.5"},
      {:jason, "== 1.4.4"},
      {:stream_data, "== 1.4.0", only: :test}
    ]
  end

  defp test_support, do: if(Mix.env() == :test, do: ["test/support"], else: [])
end
