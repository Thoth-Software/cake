defmodule Mix.Tasks.Hooks.Install do
  @moduledoc """
  Installs git hooks from priv/hooks/ into .git/hooks/.

  Usage:
      mix hooks.install

  This copies all hooks from priv/hooks/ to .git/hooks/ and makes
  them executable. Run once after cloning the repo.
  """

  use Mix.Task

  @shortdoc "Installs git hooks from priv/hooks/"

  @impl Mix.Task
  def run(_args) do
    source_dir = Path.join(["priv", "hooks"])
    target_dir = Path.join([".git", "hooks"])

    unless File.dir?(source_dir) do
      Mix.raise("No hooks directory found at #{source_dir}")
    end

    unless File.dir?(target_dir) do
      Mix.raise("No .git/hooks directory found. Are you in a git repo?")
    end

    source_dir
    |> File.ls!()
    |> Enum.each(fn hook_name ->
      source = Path.join(source_dir, hook_name)
      target = Path.join(target_dir, hook_name)

      Mix.shell().info("Installing hook: #{hook_name}")
      File.cp!(source, target)
      File.chmod!(target, 0o755)
    end)

    Mix.shell().info("Done. Git hooks installed.")
  end
end
