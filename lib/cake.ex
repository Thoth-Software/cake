defmodule Cake do
  @moduledoc """
  Cake keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.

  As a `Boundary`, `Cake` is the shared kernel: the infrastructure and
  cross-cutting contracts every context is allowed to depend on (the repo,
  base schema, mailer, the GDS behaviour, the Citable/Promptable protocols,
  citation parsing, and failed-ingest persistence). It depends on nothing
  internal; contexts depend on it, never the other way around.
  """

  use Boundary,
    deps: [],
    exports: [
      Repo,
      Schema,
      Mailer,
      GDS,
      Citable,
      Promptable,
      Citations,
      FailedIngests,
      FailedIngests.FailedIngest,
      ParseBooks
    ]
end
