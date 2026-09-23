defmodule Mix.Tasks.PrecommitTest do
  # Not async: the tests swap the global Mix shell for `Mix.Shell.Process`
  # to capture the step announcements.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Precommit

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  describe "steps/0" do
    test "runs compile, format and credo in the dev env, then the non-integration suite in the test env" do
      assert Precommit.steps() == [
               {:dev, ["compile", "--force", "--warnings-as-errors"]},
               {:dev, ["format", "--check-formatted"]},
               {:dev, ["credo", "--strict"]},
               {:test, ["test", "--exclude", "integration"]}
             ]
    end
  end

  describe "run_steps/2" do
    test "runs every step in order with its env and returns :ok when all exit 0" do
      steps = [{:dev, ["compile"]}, {:test, ["test", "--exclude", "integration"]}]
      runner = recording_runner(fn _env, _argv -> 0 end)

      assert Precommit.run_steps(steps, runner) == :ok
      assert_received {:runner, :dev, ["compile"]}
      assert_received {:runner, :test, ["test", "--exclude", "integration"]}
    end

    test "announces each step as the exact command line it runs" do
      steps = [
        {:dev, ["format", "--check-formatted"]},
        {:test, ["test", "--exclude", "integration"]}
      ]

      assert Precommit.run_steps(steps, fn _env, _argv -> 0 end) == :ok
      assert_received {:mix_shell, :info, ["==> MIX_ENV=dev mix format --check-formatted"]}
      assert_received {:mix_shell, :info, ["==> MIX_ENV=test mix test --exclude integration"]}
    end

    test "stops at the first failing step and returns it with its exit status" do
      steps = [{:dev, ["compile"]}, {:dev, ["credo", "--strict"]}, {:test, ["test"]}]

      runner =
        recording_runner(fn
          :dev, ["credo" | _] -> 3
          _env, _argv -> 0
        end)

      assert Precommit.run_steps(steps, runner) == {:error, {{:dev, ["credo", "--strict"]}, 3}}
      assert_received {:runner, :dev, ["compile"]}
      assert_received {:runner, :dev, ["credo", "--strict"]}
      refute_received {:runner, :test, ["test"]}
    end

    test "an empty step list is a no-op" do
      assert Precommit.run_steps([], fn _env, _argv -> flunk("runner must not be called") end) ==
               :ok
    end
  end

  describe "run_steps!/2" do
    test "raises a Mix.Error naming the failing step" do
      assert_raise Mix.Error, ~r/MIX_ENV=dev mix credo --strict.*exited with status 3/, fn ->
        Precommit.run_steps!([{:dev, ["credo", "--strict"]}], fn _env, _argv -> 3 end)
      end
    end
  end

  # Wraps `fun` so every call is reported back to the test process before
  # `fun` decides the exit status.
  defp recording_runner(fun) do
    test_pid = self()

    fn env, argv ->
      send(test_pid, {:runner, env, argv})
      fun.(env, argv)
    end
  end
end
