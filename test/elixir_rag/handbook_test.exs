defmodule ElixirRag.HandbookTest do
  use ExUnit.Case, async: true

  @docs Path.expand("../../priv/docs", __DIR__)

  test "every paragraph fits in one chunk, so no fact is split" do
    size = Application.fetch_env!(:elixir_rag, :chunk_size)

    for path <- Path.wildcard(Path.join(@docs, "*.md")),
        paragraph <- String.split(File.read!(path), ~r/\n\s*\n/) do
      assert String.length(String.trim(paragraph)) <= size, "#{Path.basename(path)}: #{paragraph}"
    end
  end

  test "prices agree everywhere they appear" do
    text = @docs |> Path.join("*.md") |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)
    flat = String.replace(text, ~r/\s+/, " ")

    for fact <- [
          "A Puddlewyrm costs 12 gold an hour or 60 gold for a full day",
          "A Ridgeback costs 25 gold an hour or 120 gold for a full day",
          "A Thunderwing costs 60 gold an hour or 300 gold for a full day",
          "A Mistglider costs 35 gold an hour, or 120 gold for a whole night",
          "The deposit is 100 gold for a Puddlewyrm, 250 gold for a Ridgeback, 400 gold for a Mistglider and 800 gold for a Thunderwing",
          "half-day lesson for 40 gold",
          "evening lesson for 25 gold",
          "Fire Cover costs 15 gold a day"
        ] do
      assert flat =~ fact
    end

    assert flat =~ "| Mistglider | 1 | 35 gold | 120 gold a night | 400 gold |"
    refute flat =~ ~r/Thunderwing[^.]*\b(40|50|70) gold an hour/
  end

  test "the handbook covers buying a dragon and names the head keeper" do
    text = @docs |> Path.join("*.md") |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)

    assert text =~ "You can't buy a dragon from us"
    assert text =~ "Nesta Ashryver"
  end
end
