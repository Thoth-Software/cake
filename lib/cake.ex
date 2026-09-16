defmodule Cake do
  @moduledoc """
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
