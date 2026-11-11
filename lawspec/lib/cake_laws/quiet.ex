# User-owned support module, shared by the adapters (see lawspec/README.md).
defmodule Cake.Laws.Quiet do
  @moduledoc """
  Runs Cake code that logs warnings on generated input without the noise.

  `Cake.Citations.extract/2` logs a warning per hallucinated index, and
  generated text hallucinates constantly. The warning is operational output,
  not part of any law, so adapters that reach it (`Cake.Laws.Citations`,
  `Cake.Laws.Responses`) call through `quietly/1`.
  """

  @doc """
  Calls `fun` with this process's log level raised to `:error`, restores the
  level whether `fun` returns or raises, and returns what `fun` returned.
  """
  @spec quietly((-> result)) :: result when result: var
  def quietly(fun) when is_function(fun, 0) do
    Logger.put_process_level(self(), :error)

    try do
      fun.()
    after
      Logger.delete_process_level(self())
    end
  end
end
