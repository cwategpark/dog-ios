# Initial schema

Run `python -m app.db init` against the new, isolated database before starting production API and worker. Alembic upgrades it to the latest bundled revision, initially `0001_initial`, then binds the installation to the configured Shopify store. Repeating this command is safe on a current schema. The API and worker reject an older revision until this command has run.

Versioned migration files are in `app/migrations/versions` and ship with the Python package. Existing revisions are immutable once released. Add a forward migration for each schema change, back up before upgrading, and keep changes compatible with the previous application version during rollout. A database from an earlier unversioned development build must be backed up and replaced or explicitly migrated after review; it must not be blindly stamped as current.

Another Shopify account requires a separate environment, database and private media volume. Reusing an existing installation database after changing the configured store is rejected. This command never imports or alters the WordPress source database.
