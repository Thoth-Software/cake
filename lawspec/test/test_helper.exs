# Cake.Generation.OpenAI reads its endpoint, key and plug from application
# config. The plug is the generation unit's provider (Cake.Laws.Generation):
# no request leaves the machine.
Application.put_env(:cake, Cake.Generation.OpenAI,
  openai_key: "laws",
  response_url: "http://provider.test/v1/responses",
  plug: &Cake.Laws.Generation.provider_plug/1
)

case System.get_env("LAWSPEC_SEED") do
  nil -> ExUnit.start()
  seed -> ExUnit.start(seed: String.to_integer(seed))
end

if Code.ensure_loaded?(LawSpec.Beam.ExUnitFormatter) do
  ExUnit.configure(
    formatters: Enum.uniq(ExUnit.configuration()[:formatters] ++ [LawSpec.Beam.ExUnitFormatter])
  )
end

if Code.ensure_loaded?(:lawspec_beam_resources) do
  :lawspec_beam_resources.configure_suite(Process.whereis(ExUnit.Server))
  ExUnit.after_suite(fn _ -> :lawspec_beam_resources.stop_suite() end)
end
