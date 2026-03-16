defmodule Liteskill.Repo.Migrations.CreateMemoriesAndMessageSearch do
  use Ecto.Migration

  def up do
    # --- Memories table ---
    create table(:memories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :nilify_all)
      add :category, :string, null: false, default: "insight"
      add :title, :string, null: false
      add :content, :text, null: false
      add :source_message_id, :binary_id
      add :metadata, :map, default: %{}
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:memories, [:user_id])
    create index(:memories, [:user_id, :category])
    create index(:memories, [:conversation_id])

    # --- FTS5 virtual table for message full-text search ---
    # FTS5 is compiled into SQLite by default since 3.9.0 (2015).
    # If unavailable, search gracefully falls back to LIKE queries.
    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      message_id UNINDEXED,
      conversation_id UNINDEXED,
      content,
      tokenize='porter unicode61'
    )
    """

    # Populate FTS from existing messages
    execute """
    INSERT INTO messages_fts(message_id, conversation_id, content)
    SELECT id, conversation_id, COALESCE(content, '')
    FROM messages
    WHERE content IS NOT NULL AND content != ''
    """

    # Triggers to keep FTS in sync
    execute """
    CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(message_id, conversation_id, content)
      SELECT new.id, new.conversation_id, COALESCE(new.content, '')
      WHERE new.content IS NOT NULL AND new.content != '';
    END
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE OF content ON messages BEGIN
      DELETE FROM messages_fts WHERE message_id = old.id;
      INSERT INTO messages_fts(message_id, conversation_id, content)
      SELECT new.id, new.conversation_id, COALESCE(new.content, '')
      WHERE new.content IS NOT NULL AND new.content != '';
    END
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
      DELETE FROM messages_fts WHERE message_id = old.id;
    END
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS messages_fts_delete"
    execute "DROP TRIGGER IF EXISTS messages_fts_update"
    execute "DROP TRIGGER IF EXISTS messages_fts_insert"
    execute "DROP TABLE IF EXISTS messages_fts"

    drop_if_exists index(:memories, [:conversation_id])
    drop_if_exists index(:memories, [:user_id, :category])
    drop_if_exists index(:memories, [:user_id])
    drop_if_exists table(:memories)
  end
end
