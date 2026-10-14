defmodule Cake.Repo.Migrations.AlignCoreColumnDefaults do
  use Ecto.Migration

  # Both schemas default `core` to true (`Hexdoc` and `ParsedDocument`), and
  # every Hexdoc row gets that value from the schema since `to_hexdoc_attrs/2`
  # never sets it, but the tables disagreed: `hexdocs.core` defaulted to
  # false and `parsed_documents.core` had no default at all. Align the
  # column defaults with the schemas so a row written outside Ecto (psql, a
  # bulk load) carries the same value as one written through it.
  def change do
    alter table(:hexdocs) do
      modify :core, :boolean,
        default: true,
        null: false,
        from: {:boolean, default: false, null: false}
    end

    alter table(:parsed_documents) do
      modify :core, :boolean, default: true, from: :boolean
    end
  end
end
