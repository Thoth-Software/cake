# User-owned LawSpec adapter. Implement these functions.
defmodule Cake.Laws.Generation do
  @spec provider_handler() :: LawSpec.Abilities.Cake.Laws.Generation.Provider.t()

  def provider_handler() do
    %LawSpec.Abilities.Cake.Laws.Generation.Provider{
      will_reply: fn _reply ->
        raise "Not implemented: cake.laws.generation::ability::Provider.willReply"
      end
    }
  end

  @spec generation_handler() :: LawSpec.Abilities.Cake.Laws.Generation.Generation.t()

  def generation_handler() do
    %LawSpec.Abilities.Cake.Laws.Generation.Generation{
      complete: fn _list_message, _text ->
        raise "Not implemented: cake.laws.generation::ability::Generation.complete"
      end,
      complete_json: fn _list_message, _text, _schema ->
        raise "Not implemented: cake.laws.generation::ability::Generation.completeJson"
      end
    }
  end
end
