defmodule Mix.Tasks.Precommit do
  @shortdoc "Runs the pre-push gate chain, each step in the env CI runs it in"

  @moduledoc """
  Runs the pre-push gate chain documented in CLAUDE.md as one command:

      MIX_ENV=dev  mix compile --force --warnings-as-errors
      MIX_ENV=dev  mix format --check-formatted
      MIX_ENV=dev  mix credo --strict
      MIX_ENV=test mix test --exclude integration

  Usage:
      mix precommit

  Each step is a separate `mix` process with its `MIX_ENV` set explicitly,
  so the chain runs the same way however this task is invoked. That is
  what a plain alias cannot do: an alias runs every entry inside one VM in
  one env, so `mix test` refuses to run under `:dev`, while running the
  whole alias under `:test` drops the `:boundary` compiler (dev/prod only)
  from the compile step and breaks credo, which is already started.

  The first failing step stops the chain and the task exits non-zero.
  """

  use Boundary, top_level?: true, deps: []
  use Mix.Task

  @typedoc "The Mix env a step runs in."
  @type mix_env :: :dev | :test

  @typedoc "One gate: the env to run it in and the `mix` argv to run."
  @type step :: {mix_env(), [String.t()]}

  @typedoc "Runs one step's argv under the given env and returns the exit status."
  @type runner :: (mix_env(), [String.t()] -> non_neg_integer())

  @steps [
    {:dev, ["compile", "--force", "--warnings-as-errors"]},
    {:dev, ["format", "--check-formatted"]},
    {:dev, ["credo", "--strict"]},
    {:test, ["test", "--exclude", "integration"]}
  ]

  @impl Mix.Task
  @spec run([binary()]) :: :ok
  def run(_args) do
    run_steps!(steps(), &shell_runner/2)
  end

  @doc "The gate chain, in order."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc """
  Runs `steps` in order through `runner`, stopping at the first non-zero exit.

  Returns `:ok` when every step exits 0, else `{:error, {step, status}}` for
  the step that failed.
  """
  @spec run_steps([step()], runner()) :: :ok | {:error, {step(), non_neg_integer()}}
  def run_steps(steps, runner) when is_list(steps) and is_function(runner, 2) do
    Enum.reduce_while(steps, :ok, fn {env, argv} = step, :ok ->
      Mix.shell().info("==> #{command_line(env, argv)}")

      case runner.(env, argv) do
        0 -> {:cont, :ok}
        status -> {:halt, {:error, {step, status}}}
      end
    end)
  end

  @doc "Like `run_steps/2`, but raises `Mix.Error` naming the failing step."
  @spec run_steps!([step()], runner()) :: :ok
  def run_steps!(steps, runner) when is_list(steps) and is_function(runner, 2) do
    case run_steps(steps, runner) do
      :ok ->
        :ok

      {:error, {{env, argv}, status}} ->
        Mix.raise("mix precommit: `#{command_line(env, argv)}` exited with status #{status}")
    end
  end

  # Runs the step as a child `mix` process (found on PATH) with MIX_ENV set,
  # streaming its output through the Mix shell.
  @spec shell_runner(mix_env(), [String.t()]) :: non_neg_integer()
  defp shell_runner(env, argv) do
    Mix.shell().cmd("mix " <> Enum.join(argv, " "), env: [{"MIX_ENV", Atom.to_string(env)}])
  end

  @spec command_line(mix_env(), [String.t()]) :: String.t()
  defp command_line(env, argv), do: "MIX_ENV=#{env} mix #{Enum.join(argv, " ")}"
end
