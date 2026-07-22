defmodule Cake.Jobs do
  @moduledoc """
  Oban background jobs.

  This module is the `Boundary` anchor for the `Cake.Jobs.*` namespace.
  """

  use Boundary, top_level?: true, deps: [Cake, Cake.Documents], exports: []
end
