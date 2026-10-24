defmodule ElixirRag.LLM do
  @moduledoc """
  The model provider behind the pipeline, set with `config :elixir_rag, llm: Module`.

  `embedding_signature/0` names the model and size that produce the embeddings,
  e.g. `"gemini-embedding-001@768"`. Every stored chunk is stamped with it.
  """

  @callback embed_documents(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  @callback embed_query(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
  @callback generate(system :: String.t(), prompt :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback embedding_signature() :: String.t()

  def impl, do: Application.fetch_env!(:elixir_rag, :llm)
end
