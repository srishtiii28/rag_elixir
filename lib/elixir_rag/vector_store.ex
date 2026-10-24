defmodule ElixirRag.VectorStore do
  @moduledoc """
  Chunks and their embeddings in Postgres, searched by cosine distance.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias ElixirRag.{Chunk, Repo}

  @doc "Replaces every chunk of `source` in one transaction."
  def replace_source(source, contents, embeddings, signature) do
    now = DateTime.utc_now(:second)

    rows =
      for {{content, embedding}, index} <- Enum.with_index(Enum.zip(contents, embeddings)) do
        %{
          source: source,
          chunk_index: index,
          content: content,
          embedding: Pgvector.new(embedding),
          embedding_model: signature,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.transaction(fn ->
      Repo.delete_all(from(c in Chunk, where: c.source == ^source))
      {count, _} = Repo.insert_all(Chunk, rows)
      count
    end)
  end

  @doc "Returns the `top_k` chunks nearest to `embedding`, nearest first."
  def search(embedding, top_k \\ 5) do
    vector = Pgvector.new(embedding)

    from(c in Chunk,
      order_by: cosine_distance(c.embedding, ^vector),
      limit: ^top_k,
      select: %{
        source: c.source,
        chunk_index: c.chunk_index,
        content: c.content,
        distance: cosine_distance(c.embedding, ^vector)
      }
    )
    |> Repo.all()
  end

  def delete_except(sources) do
    Repo.delete_all(from(c in Chunk, where: c.source not in ^sources))
  end

  def signatures do
    Repo.all(from(c in Chunk, distinct: true, select: c.embedding_model))
  end

  def sources do
    Repo.all(from(c in Chunk, distinct: true, select: c.source, order_by: c.source))
  end

  def count, do: Repo.aggregate(Chunk, :count)
end
