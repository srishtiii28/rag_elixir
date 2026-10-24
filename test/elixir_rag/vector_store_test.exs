defmodule ElixirRag.VectorStoreTest do
  use ElixirRag.DataCase, async: true

  alias ElixirRag.VectorStore

  defp basis(i), do: List.duplicate(0.0, 768) |> List.replace_at(i, 1.0)
  defp scale(v, k), do: Enum.map(v, &(&1 * k))
  defp add(a, b), do: Enum.zip_with(a, b, &+/2)

  test "returns the nearest chunks first, by cosine distance" do
    {:ok, 3} =
      VectorStore.replace_source(
        "doc.md",
        ["far", "near", "middle"],
        [basis(1), scale(basis(0), 5.0), add(basis(0), basis(1))],
        "test@768"
      )

    results = VectorStore.search(basis(0), 3)

    assert Enum.map(results, & &1.content) == ["near", "middle", "far"]
    [near, middle, far] = Enum.map(results, & &1.distance)
    assert_in_delta near, 0.0, 1.0e-6
    assert_in_delta middle, 1 - :math.sqrt(0.5), 1.0e-6
    assert_in_delta far, 1.0, 1.0e-6
  end

  test "limits the results to top_k" do
    {:ok, 3} =
      VectorStore.replace_source("doc.md", ~w(a b c), [basis(0), basis(1), basis(2)], "test@768")

    assert length(VectorStore.search(basis(0), 2)) == 2
  end

  test "replacing a source removes its old chunks" do
    {:ok, 3} =
      VectorStore.replace_source("doc.md", ~w(a b c), [basis(0), basis(1), basis(2)], "test@768")

    {:ok, 1} = VectorStore.replace_source("doc.md", ~w(d), [basis(3)], "test@768")

    assert VectorStore.count() == 1
  end

  test "delete_except keeps only the named sources" do
    {:ok, _} = VectorStore.replace_source("keep.md", ~w(a), [basis(0)], "test@768")
    {:ok, _} = VectorStore.replace_source("gone.md", ~w(b), [basis(1)], "test@768")

    VectorStore.delete_except(["keep.md"])

    assert VectorStore.sources() == ["keep.md"]
  end
end
