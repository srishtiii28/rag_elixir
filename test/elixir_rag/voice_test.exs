defmodule ElixirRag.VoiceTest do
  use ExUnit.Case, async: true

  alias ElixirRag.Voice
  alias ElixirRag.Voice.Dragonkeeper

  test "the dragonkeeper is the default voice" do
    assert Voice.impl() == Dragonkeeper
  end

  test "the dragonkeeper keeps the grounding rules" do
    prompt = Voice.system_prompt(Dragonkeeper)

    assert prompt =~ "using only the numbered passages"
    assert prompt =~ "say that you don't know"
    assert prompt =~ "Nesta Ashryver, head dragonkeeper"
    assert prompt =~ "Never make up a new habit"
    assert prompt =~ "never give one dragon's habit to another"
    assert prompt =~ "never invent offers"
  end

  test "a retry adds a reminder to the same persona" do
    prompt = Voice.system_prompt(Dragonkeeper, retry: true)

    assert prompt =~ "Nesta Ashryver"
    assert prompt =~ "Answer again without it."
    refute Voice.system_prompt(Dragonkeeper) =~ "Answer again"
  end

  test "the dragonkeeper rejects pushy or out-of-character phrasing" do
    for text <- [
          "Act now to secure your dragon!",
          "This is a limited-time price.",
          "Don't miss out on a Thunderwing.",
          "Hurry, only 2 left!",
          "We guarantee you'll love it.",
          "Book today!!",
          "The passages don't say how old Gerald is.",
          "Passages don't say who is the fastest dragon overall.",
          "According to the documents, the deposit is 250 gold [1].",
          "As an AI, I can't ride dragons."
        ] do
      assert {:error, {:forbidden, _}} = Voice.check(Dragonkeeper, "deposit", text), text
    end
  end

  test "the dragonkeeper accepts a fond, grounded answer" do
    for text <- [
          "The deposit for a Ridgeback is 250 gold [1]. We return it within 5 days, " <>
            "provided Gerald comes home in a good mood, which he usually does [1].",
          "We don't sell dragons, at any price [2]. You can sponsor one for 5 gold a month [2]. " <>
            "Dumpling would like that very much!",
          "Light the red flare and stay where you are [1]."
        ] do
      assert Voice.check(Dragonkeeper, "deposit", text) == :ok, text
    end
  end

  test "the dragonkeeper only greets a visitor who greets first" do
    text = "Hello! The deposit for a Ridgeback is 250 gold [1]."

    assert Voice.check(Dragonkeeper, "how much is the deposit", text) ==
             {:error, :unprompted_greeting}

    assert Voice.check(Dragonkeeper, "hi, how much is the deposit", text) == :ok
    assert Voice.check(Dragonkeeper, "Hello there", "Hello. What can I help with?") == :ok
  end

  test "greetings, thanks and who-are-you are small talk; questions are not" do
    for {text, kind} <- [
          {"hi", :greeting},
          {"Hello there!", :greeting},
          {"hi nesta", :greeting},
          {"thanks", :thanks},
          {"Thank you so much!", :thanks},
          {"Who are you?", :introduction},
          {"what's your name", :introduction}
        ] do
      assert Voice.small_talk(text) == kind, text
    end

    for text <- [
          "hi, how much is the deposit?",
          "who is your fastest dragon",
          "thanks, and Hazel?"
        ] do
      assert Voice.small_talk(text) == nil, text
    end
  end

  test "the dragonkeeper's small talk passes her own check" do
    for kind <- [:greeting, :thanks, :introduction] do
      assert Voice.check(Dragonkeeper, "hi", Dragonkeeper.small_talk(kind)) == :ok
    end
  end

  test "the dragonkeeper may greet a visitor who asks who she is" do
    text = "Hello, I'm Nesta Ashryver, head dragonkeeper at Ember & Scale Dragon Hire."

    assert Voice.check(Dragonkeeper, "who are you?", text) == :ok
    assert Voice.check(Dragonkeeper, "What's your name?", text) == :ok
  end
end
