defmodule Caque.ParseBooks do
  use Rustler, otp_app: :caque, crate: "parsebooks"

  @spec add(integer(), integer()) :: integer()
  def add(a, b), do: :erlang.nif_error(:nif_not_loaded)
end
