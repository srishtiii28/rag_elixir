defmodule ElixirRag.IndexerTest do
  use ElixirRag.DataCase, async: true

  import Mox

  alias ElixirRag.{FakeLLM, Indexer, MockLLM, VectorStore}

  setup :verify_on_exit!
  setup do: stub_with(MockLLM, FakeLLM) && :ok

  @tag :tmp_dir
  test "indexes every document in a directory", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.md"), "Alpha.\n\nMore alpha.")
    File.mkdir_p!(Path.join(dir, "nested"))
    File.write!(Path.join(dir, "nested/b.txt"), "Beta.")
    File.write!(Path.join(dir, "ignored.pdf"), "not text")

    assert {:ok, 2} = Indexer.index_dir(dir)
    assert VectorStore.sources() == ["a.md", "nested/b.txt"]
    assert Indexer.status() == :ok
  end

  @tag :tmp_dir
  test "indexing again replaces chunks and drops deleted documents", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.md"), "Alpha.")
    File.write!(Path.join(dir, "b.md"), "Beta.")
    {:ok, 2} = Indexer.index_dir(dir)

    File.rm!(Path.join(dir, "b.md"))
    {:ok, 1} = Indexer.index_dir(dir)

    assert VectorStore.count() == 1
    assert VectorStore.sources() == ["a.md"]
  end

  @tag :tmp_dir
  test "an empty directory is an error and deletes nothing", %{tmp_dir: dir} do
    {:ok, _} = VectorStore.replace_source("old.md", ["x"], [FakeLLM.vector("x")], "fake@768")

    assert {:error, {:no_documents, ^dir}} = Indexer.index_dir(dir)
    assert VectorStore.count() == 1
  end

  @tag :tmp_dir
  test "an embedding failure is returned with the document name", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.md"), "Alpha.")
    expect(MockLLM, :embed_documents, fn _ -> {:error, :rate_limited} end)

    assert {:error, {"a.md", :rate_limited}} = Indexer.index_dir(dir)
  end

  test "status reports an index built with another embedding model as stale" do
    assert Indexer.status() == :empty

    {:ok, _} = VectorStore.replace_source("old.md", ["x"], [FakeLLM.vector("x")], "old-model@768")

    assert Indexer.status() == :stale
  end
end
