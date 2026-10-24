defmodule ElixirRag.Chunker do
  @moduledoc """
  Splits text into overlapping chunks of at most `:size` characters.

  Paragraphs are packed together until the next one would overflow the chunk.
  Each new chunk starts with the last `:overlap` characters of the previous
  one, cut at a word boundary. A paragraph longer than `:size` is split into
  windows of its own.
  """

  @doc """
  ## Options

    * `:size` - maximum characters per chunk (default 400)
    * `:overlap` - characters carried over between chunks (default 60)
  """
  def chunk(text, opts \\ []) do
    size = Keyword.get(opts, :size, 400)
    overlap = Keyword.get(opts, :overlap, 60)

    if overlap >= size, do: raise(ArgumentError, ":overlap must be smaller than :size")

    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&split_long(&1, size, overlap))
    |> pack(size, overlap)
  end

  defp split_long(paragraph, size, overlap) do
    length = String.length(paragraph)

    if length <= size do
      [paragraph]
    else
      [first | rest] =
        0
        |> Stream.iterate(&(&1 + size - overlap))
        |> Enum.take_while(&(&1 == 0 or &1 + overlap < length))
        |> Enum.map(&String.slice(paragraph, &1, size))

      [first | Enum.map(rest, &{:window, &1})]
    end
  end

  defp pack(pieces, size, overlap) do
    {chunks, current} =
      Enum.reduce(pieces, {[], nil}, fn
        {:window, window}, {chunks, current} ->
          {[current | chunks], window}

        piece, {chunks, nil} ->
          {chunks, piece}

        piece, {chunks, current} ->
          joined = current <> "\n\n" <> piece

          if String.length(joined) <= size do
            {chunks, joined}
          else
            {[current | chunks], start_next(current, piece, size, overlap)}
          end
      end)

    if current, do: Enum.reverse([current | chunks]), else: Enum.reverse(chunks)
  end

  defp start_next(previous, piece, size, overlap) do
    carried = tail(previous, overlap)
    next = if carried == "", do: piece, else: carried <> "\n\n" <> piece
    if String.length(next) <= size, do: next, else: piece
  end

  defp tail(text, n) do
    if String.length(text) <= n do
      text
    else
      case text |> String.slice(-n, n) |> String.split(~r/\s+/, parts: 2) do
        [_partial_word, rest] -> rest
        [_] -> ""
      end
    end
  end
end
