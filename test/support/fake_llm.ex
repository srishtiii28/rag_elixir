defmodule ElixirRag.FakeLLM do
  @moduledoc """
  An offline stand-in for a real model, used with `Mox.stub_with/2`.

  Its embeddings are word counts hashed into 768 slots, so texts that share
  words land close together. The first slot is a small constant so that text
  with no words still has a direction.
  """

  @behaviour ElixirRag.LLM

  @dims 768
  @stopwords ~w(a an and are can do for how i in is it much of on or the to what when you)

  @impl true
  def embed_documents(texts), do: {:ok, Enum.map(texts, &vector/1)}

  @impl true
  def embed_query(text), do: {:ok, vector(text)}

  @impl true
  def generate(_system, _prompt), do: {:ok, "fake answer"}

  @impl true
  def embedding_signature, do: "fake@#{@dims}"

  def vector(text) do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.reject(&(&1 in @stopwords))
      |> Enum.map(&String.trim_trailing(&1, "s"))
      |> Enum.frequencies_by(&:erlang.phash2(&1, @dims - 1))

    [0.01 | for(i <- 0..(@dims - 2), do: Map.get(counts, i, 0) * 1.0)]
  end
end
