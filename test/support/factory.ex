defmodule Cake.Factory do
  @moduledoc "ExMachina factory for test data. Import via DataCase, ConnCase, or ObanCase."

  use ExMachina.Ecto, repo: Cake.Repo
end
