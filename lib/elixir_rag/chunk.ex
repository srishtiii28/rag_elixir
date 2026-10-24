defmodule ElixirRag.Chunk do
  @moduledoc "One embedded piece of a source document."
  use Ecto.Schema

  schema "chunks" do
    field :source, :string
    field :chunk_index, :integer
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_model, :string

    timestamps(type: :utc_datetime)
  end
end
