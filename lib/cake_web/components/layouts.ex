defmodule CakeWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use CakeWeb, :controller` and
  `use CakeWeb, :live_view`.
  """
  use CakeWeb, :html

  embed_templates "layouts/*"
end
