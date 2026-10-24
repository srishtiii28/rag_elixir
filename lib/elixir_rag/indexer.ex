defmodule ElixirRag.Indexer do
  @moduledoc """
  Chunks, embeds and stores every `.md` and `.txt` file in a directory.

  Each file is a source named by its path relative to the directory.
  """

  require Logger

  alias ElixirRag.{Chunker, LLM, VectorStore}

  @extensions ~w(.md .txt)

  @doc """
  Compares the stored chunks with the configured embedding model.

  Returns `:empty`, `:ok`, or `:stale` when some chunks were embedded by a
  different model or size and need re-indexing.
  """
  def status do
    signature = LLM.impl().embedding_signature()

    case VectorStore.signatures() do
      [] -> :empty
      [^signature] -> :ok
      _ -> :stale
    end
  end

  @doc """
  Indexes every document in `dir` and deletes chunks of documents that are no
  longer there. Returns `{:ok, chunk_count}`.
  """
  def index_dir(dir \\ docs_dir()) do
    files =
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&(Path.extname(&1) in @extensions))
      |> Enum.sort()

    if files == [] do
      {:error, {:no_documents, dir}}
    else
      sources = Enum.map(files, &Path.relative_to(&1, dir))
      VectorStore.delete_except(sources)

      files
      |> Enum.zip(sources)
      |> Enum.reduce_while({:ok, 0}, fn {path, source}, {:ok, total} ->
        case index_file(path, source) do
          {:ok, count} -> {:cont, {:ok, total + count}}
          {:error, reason} -> {:halt, {:error, {source, reason}}}
        end
      end)
    end
  end

  def index_file(path, source) do
    llm = LLM.impl()

    chunks =
      path
      |> File.read!()
      |> Chunker.chunk(
        size: Application.fetch_env!(:elixir_rag, :chunk_size),
        overlap: Application.fetch_env!(:elixir_rag, :chunk_overlap)
      )

    with {:ok, embeddings} <- llm.embed_documents(chunks),
         :ok <- same_length(chunks, embeddings),
         {:ok, count} <-
           VectorStore.replace_source(source, chunks, embeddings, llm.embedding_signature()) do
      Logger.info("Indexed #{source}: #{count} chunks")
      {:ok, count}
    end
  end

  def docs_dir do
    Application.get_env(:elixir_rag, :docs_dir) || Application.app_dir(:elixir_rag, "priv/docs")
  end

  defp same_length(chunks, embeddings) when length(chunks) == length(embeddings), do: :ok

  defp same_length(chunks, embeddings),
    do: {:error, {:embedding_count_mismatch, length(chunks), length(embeddings)}}
end
