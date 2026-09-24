defmodule Cake.SearchIntegrationCaseUnitTest do
  @moduledoc """
  The pure parts of `Cake.SearchIntegrationCase`, as plain unit tests that
  never touch a cluster: `integration_run?/1` over the shapes ExUnit's
  include list can take (bare tags from `--only integration`, keyword
  entries from `--only integration:true`), and `run_mode/2`, which
  `test_helper.exs` uses to pick the run mode and to refuse a mixed
  unit-and-integration run.
  """

  use ExUnit.Case, async: true

  alias Cake.SearchIntegrationCase

  describe "integration_run?/1" do
    test "is false for an empty include list" do
      refute SearchIntegrationCase.integration_run?([])
    end

    test "is true for the bare tag mix emits for --only integration" do
      assert SearchIntegrationCase.integration_run?([:integration])
    end

    test "is true for a keyword entry, whatever its value" do
      assert SearchIntegrationCase.integration_run?(integration: true)
      assert SearchIntegrationCase.integration_run?(integration: "true")
    end

    test "is false when only other tags are included" do
      refute SearchIntegrationCase.integration_run?([:slow, other: true])
    end
  end

  describe "run_mode/2" do
    test "a plain run is a unit run" do
      assert SearchIntegrationCase.run_mode([], []) == :unit
    end

    test "excluding integration (the on-push CI shape) is a unit run" do
      assert SearchIntegrationCase.run_mode([], [:integration]) == :unit
    end

    test "--only integration (include it, exclude :test) is an integration run" do
      assert SearchIntegrationCase.run_mode([:integration], [:test]) == :integration
      assert SearchIntegrationCase.run_mode([integration: true], [:test]) == :integration
    end

    test "--include integration alone is refused: unit tests would hit the real cluster" do
      assert_raise ArgumentError, ~r/--only integration/, fn ->
        SearchIntegrationCase.run_mode([:integration], [])
      end

      assert_raise ArgumentError, ~r/--only integration/, fn ->
        SearchIntegrationCase.run_mode([:integration], [:integration])
      end
    end
  end
end
