defmodule ElixirRag.ChunkerTest do
  use ExUnit.Case, async: true

  alias ElixirRag.Chunker

  defp paragraph(n), do: "Paragraph #{n}. " <> String.duplicate("word#{n} ", 40)

  test "empty text has no chunks" do
    assert Chunker.chunk("") == []
    assert Chunker.chunk("\n\n  \n") == []
  end

  test "short text is one chunk" do
    assert Chunker.chunk("One.\n\nTwo.") == ["One.\n\nTwo."]
  end

  test "no chunk is longer than the size" do
    text = Enum.map_join(1..20, "\n\n", &paragraph/1)

    chunks = Chunker.chunk(text, size: 500, overlap: 50)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= 500))
  end

  test "each chunk starts with the end of the previous one" do
    text = Enum.map_join(1..10, "\n\n", &paragraph/1)

    chunks = Chunker.chunk(text, size: 600, overlap: 80)

    for [previous, next] <- Enum.chunk_every(chunks, 2, 1, :discard) do
      [carried | _] = String.split(next, "\n\n")
      assert String.ends_with?(previous, carried)
    end
  end

  test "every paragraph ends up in a chunk" do
    text = Enum.map_join(1..10, "\n\n", &paragraph/1)
    chunks = Chunker.chunk(text, size: 600, overlap: 80)

    for n <- 1..10,
        do: assert(Enum.any?(chunks, &String.contains?(&1, paragraph(n) |> String.trim())))
  end

  test "a paragraph longer than the size is split into overlapping windows" do
    long = String.duplicate("abcdefghij", 100)

    chunks = Chunker.chunk(long, size: 300, overlap: 50)

    assert Enum.all?(chunks, &(String.length(&1) <= 300))
    assert String.starts_with?(long, hd(chunks))
    assert String.ends_with?(long, List.last(chunks))
  end

  test "the windows of a long paragraph overlap once, not twice" do
    long = Enum.map_join(1..60, " ", &"w#{&1}")

    chunks = Chunker.chunk(long <> "\n\nThe end.", size: 120, overlap: 30)

    for chunk <- chunks do
      words = String.split(chunk)
      assert words == Enum.uniq(words), "repeated text in #{inspect(chunk)}"
    end

    assert List.last(chunks) =~ ~r/w60\n\nThe end\.\z/
  end

  test "overlap must be smaller than size" do
    assert_raise ArgumentError, fn -> Chunker.chunk("text", size: 100, overlap: 100) end
  end
end
