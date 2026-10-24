defmodule ElixirRag.Repo.Migrations.CreateChunks do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:chunks) do
      add :source, :string, null: false
      add :chunk_index, :integer, null: false
      add :content, :text, null: false
      add :embedding, :vector, size: 768, null: false
      add :embedding_model, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chunks, [:source, :chunk_index])

    execute "CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw (embedding vector_cosine_ops)"
  end

  def down do
    drop table(:chunks)
  end
end
