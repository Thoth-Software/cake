defmodule Cake.SearchIntegrationCasePredicateTest do
  @moduledoc """
  `Cake.SearchIntegrationCase.integration_run?/1`, the predicate
  `test_helper.exs` uses to pick the run mode, over the shapes ExUnit's
  include list can take: bare tags (`--only integration`) and keyword
  entries (`--only integration:true`). A plain unit test: it never touches
  a cluster.
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
end
