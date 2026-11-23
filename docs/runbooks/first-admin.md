# Creating logins, and the first admin

How an operator gives someone a login, and how the first admin is made when no screen can make one. What a login is, and the rule that there is always at least one admin, are under "Roles and the First Admin" in `docs/architecture/web.md`.

## A login for someone

An admin opens Admin, then Logins, then "New login" (`/admin/users/new`), types a username, the person's email and a password, picks a role, and tells the person the password. The login works at once (see "Confirmation" in `docs/architecture/web.md`). To change it later, open the login from the list and use "Set password", which also logs that person out everywhere.

## The first admin

No screen can create the first admin, because every admin screen needs an admin. It is created by calling `Cake.Accounts.create_user/1` with a username, an email, a password and a role. All four are required. The password must never be an argument on the command line, where it is left in the shell history and shown in the process list.

In dev the call runs in the process you start, so the password can come from the environment. `IFS= read -rs` takes it without echoing it, recording it, or trimming spaces from its ends:

```bash
IFS= read -rs ADMIN_PASSWORD && export ADMIN_PASSWORD
mix run -e 'case Cake.Accounts.create_user(%{username: "caleb", email: "caleb@example.com", password: System.fetch_env!("ADMIN_PASSWORD"), role: :admin}) do {:ok, user} -> IO.puts("created #{user.username} (#{user.role})"); {:error, changeset} -> IO.inspect(changeset.errors); System.halt(1) end'
```

In a release (#361) the call goes through `bin/cake rpc`, which evaluates the expression on the running node. That node does not have the environment of the shell that ran `rpc`, so the password comes from standard input, which `rpc` does pass through:

```bash
IFS= read -rs ADMIN_PASSWORD
printf '%s\n' "$ADMIN_PASSWORD" | bin/cake rpc 'case Cake.Accounts.create_user(%{username: "caleb", email: "caleb@example.com", password: String.trim_trailing(IO.read(:stdio, :line), "\n"), role: :admin}) do {:ok, user} -> IO.puts("created #{user.username} (#{user.role})"); {:error, changeset} -> raise "not created: #{inspect(changeset.errors)}" end'
```

Three details of that command matter to a script that runs it:

- `printf` is a shell builtin, so the password is not in the process list either.
- Only the line's newline is removed (`String.trim_trailing/2`), so a password that begins or ends with a space is the one stored.
- On failure it raises. The `rpc` command then exits non-zero, so a script stops there, and the running node is unaffected. It must not call `System.halt/1`, which would stop the node it runs on.
