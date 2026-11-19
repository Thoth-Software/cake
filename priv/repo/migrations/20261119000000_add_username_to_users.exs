defmodule Cake.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  # A user logs in with a username (#372). `username` is `citext`, so it is
  # compared case-insensitively and stored as typed; it is required and
  # unique. `email` stays, keeps its unique index, and becomes optional.
  #
  # Only dev and test databases exist, and nothing is deployed. Their rows are
  # carried over all the same.
  #
  # Up: every existing row gets a username made from the local part of its
  # email. A character outside the username set (`a-z`, `0-9`, `_`, `.`, `-`,
  # either letter case) becomes `_`; the result is cut to 32 characters and
  # padded with `_` to 3, so it satisfies the rule `Cake.Accounts.User`
  # validates. Rows are taken oldest first. The first row to want a name
  # keeps it; a later one gets `-2`, `-3` and so on, with the name cut
  # further where the suffix would pass 32 characters. A suffixed name is
  # checked like any other, so `bob`, `bob` and `bob-2` end as `bob`,
  # `bob-2` and `bob-2-2`.
  #
  # Down: `email` is required again, so a user registered without one is given
  # `<username>@users.invalid` (`.invalid` is reserved by RFC 2606 and never
  # deliverable). Nothing stops another user from having typed that very
  # address as their email, so where it is taken the domain becomes
  # `users-2.invalid`, `users-3.invalid` and so on. It is the domain that
  # changes and not the local part, so migrating up again still makes the
  # same username from it. What a rollback cannot keep is the username of a
  # user who also has an email: the old table has no column for it, and the
  # next `up` derives a new one from the email.
  def up do
    alter table(:users) do
      add :username, :citext
    end

    execute """
    DO $$
    DECLARE
      account RECORD;
      base text;
      candidate citext;
      suffix text;
      attempt integer;
    BEGIN
      FOR account IN SELECT id, email FROM users ORDER BY inserted_at, id LOOP
        base := left(
          regexp_replace(split_part(account.email, '@', 1), '[^a-zA-Z0-9_.-]', '_', 'g'),
          32
        );

        -- Only a short name is padded: rpad cuts a longer one down to its length.
        IF length(base) < 3 THEN
          base := rpad(base, 3, '_');
        END IF;

        candidate := base;
        attempt := 1;

        WHILE EXISTS (SELECT 1 FROM users WHERE username = candidate) LOOP
          attempt := attempt + 1;
          suffix := '-' || attempt;
          candidate := left(base, 32 - length(suffix)) || suffix;
        END LOOP;

        UPDATE users SET username = candidate WHERE id = account.id;
      END LOOP;
    END
    $$;
    """

    alter table(:users) do
      modify :username, :citext, null: false
      modify :email, :citext, null: true
    end

    create unique_index(:users, [:username])
  end

  def down do
    execute """
    DO $$
    DECLARE
      account RECORD;
      candidate citext;
      attempt integer;
    BEGIN
      FOR account IN
        SELECT id, username FROM users WHERE email IS NULL ORDER BY inserted_at, id
      LOOP
        candidate := account.username || '@users.invalid';
        attempt := 1;

        WHILE EXISTS (SELECT 1 FROM users WHERE email = candidate) LOOP
          attempt := attempt + 1;
          candidate := account.username || '@users-' || attempt || '.invalid';
        END LOOP;

        UPDATE users SET email = candidate WHERE id = account.id;
      END LOOP;
    END
    $$;
    """

    drop unique_index(:users, [:username])

    alter table(:users) do
      remove :username
      modify :email, :citext, null: false
    end
  end
end
