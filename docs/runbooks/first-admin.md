# Creating logins, the first admin, and getting an admin back in

How an operator gives someone a login, how the first admin is made when no screen can make one, and how to get an admin back in when none can log in. What a login is, and the rule that there is always at least one admin, are under "Roles and the First Admin" in `docs/architecture/web.md`.

## A login for someone

An admin opens Admin, then "Manage logins", then "New login" (`/admin/users/new`), types a username, the person's email and a password, picks a role, and tells the person the password. The login works at once (see "Confirmation" in `docs/architecture/web.md`). To change it later, open the login from the list and use "Set password", which also logs that person out everywhere.

## The first admin

No screen can create the first admin, because every admin screen needs an admin. It is created by calling `Cake.Accounts.create_user/1` with a username, an email, a password and a role. All four are required. The password must never be an argument on the command line, where it is left in the shell history and shown in the process list.

In dev the call runs in the process you start, so the password can come from the environment. `IFS= read -rs` takes it without echoing it, recording it, or trimming spaces from its ends:

```bash
IFS= read -rs ADMIN_PASSWORD && export ADMIN_PASSWORD
mix run -e 'case Cake.Accounts.create_user(%{username: "caleb", email: "caleb@example.com", password: System.fetch_env!("ADMIN_PASSWORD"), role: :admin}) do {:ok, user} -> IO.puts("created #{user.username} (#{user.role})"); {:error, changeset} -> IO.inspect(changeset.errors); System.halt(1) end'
```

In a release the call goes through `bin/cake rpc`, which evaluates the expression on the running node. That node does not have the environment of the shell that ran `rpc`, so the password comes from standard input, which `rpc` does pass through:

```bash
IFS= read -rs ADMIN_PASSWORD
printf '%s\n' "$ADMIN_PASSWORD" | bin/cake rpc 'case Cake.Accounts.create_user(%{username: "caleb", email: "caleb@example.com", password: String.trim_trailing(IO.read(:stdio, :line), "\n"), role: :admin}) do {:ok, user} -> IO.puts("created #{user.username} (#{user.role})"); {:error, changeset} -> raise "not created: #{inspect(changeset.errors)}" end'
```

Three details of that command matter to a script that runs it:

- `printf` is a shell builtin, so the password is not in the process list either.
- Only the line's newline is removed (`String.trim_trailing/2`), so a password that begins or ends with a space is the one stored.
- On failure it raises. The `rpc` command then exits non-zero, so a script stops there, and the running node is unaffected. It must not call `System.halt/1`, which would stop the node it runs on.

## When no admin can log in

An admin who is not confirmed cannot log in, and `Cake.Accounts` refuses to take away the last confirmed admin ("Roles and the First Admin" in `docs/architecture/web.md`). If no admin is confirmed anyway (a database from before that rule, or a row changed behind `Cake.Accounts`), confirm one from the command line, by their email: `Cake.Accounts` never refuses a confirmation. In dev:

```bash
mix run -e 'user = Cake.Accounts.get_user_by_email("caleb@example.com"); {:ok, user} = Cake.Accounts.set_user_confirmed(:operator, user, true); IO.puts("confirmed #{user.username} (#{user.role})")'
```

In a release, on the running node:

```bash
bin/cake rpc 'user = Cake.Accounts.get_user_by_email("caleb@example.com"); {:ok, user} = Cake.Accounts.set_user_confirmed(:operator, user, true); IO.puts("confirmed #{user.username} (#{user.role})")'
```

An email no user has raises, so the command exits non-zero and changes nothing. If the user it confirms is a member, make them an admin the same way, with `Cake.Accounts.update_user_role(user, :admin)`.
