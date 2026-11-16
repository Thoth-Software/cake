# User-owned LawSpec adapter. Implement these functions.
defmodule Cake.Laws.DecompositionLlm do
  @spec llm_decompose(
          LawSpec.Abilities.Cake.Laws.Generation.Generation.t(),
          binary(),
          :absent
          | {:present, binary()}
        ) :: {:left, LawSpec.Data.decomposition_error()} | {:right, LawSpec.Data.decomposition()}

  def llm_decompose(_generation_handler, _text, _maybe_text) do
    raise "Not implemented: cake.laws.decomposition_llm::llmDecompose"
  end

  @spec result_new(binary(), [binary()]) :: LawSpec.Data.decomposition()

  def result_new(_text, _list_text) do
    raise "Not implemented: cake.laws.decomposition_llm::resultNew"
  end

  @spec decomposition_prompt(binary()) :: [LawSpec.Data.message()]

  def decomposition_prompt(_text) do
    raise "Not implemented: cake.laws.decomposition_llm::decompositionPrompt"
  end
end
