defmodule Cake.Repo.Migrations.RequireEmailOnUsers do
  use Ecto.Migration

  # Every user has an email (#377), which #372 had made optional. A user
  # logs in with the username still; the email is what confirmation and
  # password reset are sent to, and log-in waits on its confirmation.
  #
  # There is no backfill, for the reason `AddUsernameToUsers` gives: nothing
  # is deployed. On a database that has a user without an email, migrating
  # up stops before it changes anything and says how many there are. Give
  # each of them an email or delete them, or reset the database
  # (`mix ecto.reset`, or `docker compose down -v` for the dev stack).
  def up do
    execute("""
    DO $$
    DECLARE
      missing integer;
    BEGIN
      SELECT count(*) INTO missing FROM users WHERE email IS NULL;

      IF missing > 0 THEN
        RAISE EXCEPTION
          'users.email is now required, and % user(s) have none. Give each an email or delete them (or reset the database), then migrate again.',
          missing;
      END IF;
    END
    $$;
    """)

    alter table(:users) do
      modify :email, :citext, null: false, from: {:citext, null: true}
    end
  end

  def down do
    alter table(:users) do
      modify :email, :citext, null: true, from: {:citext, null: false}
    end
  end
end
