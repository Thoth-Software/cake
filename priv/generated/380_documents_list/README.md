# Raw generator output for #380

Unedited output of, on Phoenix 1.8.16:

    mix phx.gen.live Books ParsedBook parsed_books title:string total_pages:integer word_count:integer authors:array:string embedding_status:enum:pending:processing:completed:failed --no-context --no-scope

The files sit here, under the paths the generator wrote them to, for this
one commit: at their real paths they fail `mix compile --warnings-as-errors`
(no `/parsed_books` routes, no `current_user` for `Layouts.app`), and the
generated tests fail by design with `--no-context`. The commits that follow
move them into place and edit them, so every edit reads as a diff against
this. The directory is gone by the end of the branch.
