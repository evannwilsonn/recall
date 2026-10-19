defmodule Recall.LearningTest do
  use ExUnit.Case, async: true

  alias Recall.{Deck, Grader, Writer}

  describe "grader pieces" do
    test "content words drop stop words and trim endings" do
      assert Grader.content_words("The pointers are sorted using a queue") == [
               "pointer",
               "sort",
               "using",
               "queue"
             ]
    end

    test "coverage counts the reference's key words you used, and lists the rest" do
      o = Grader.overlap("A stack is last in, first out", "a stack: last in first out")
      assert o.coverage == 1.0
      o = Grader.overlap("A stack is last in, first out", "a stack holds things")
      assert o.coverage < 0.5
      assert "last" in o.missing
    end

    test "least squares recovers a known line" do
      rows = for x <- 0..20, do: [1.0, x / 20]
      ys = for [_, x] <- rows, do: 1.0 + 3.0 * x
      [b, w] = Grader.fit(rows, ys)
      assert_in_delta b, 1.0, 0.01
      assert_in_delta w, 3.0, 0.01
    end

    test "bands from scores and cut-offs" do
      cut = %{"partly" => 2.0, "right" => 3.5}
      assert Grader.band(4.0, cut) == :right
      assert Grader.band(2.5, cut) == :partly
      assert Grader.band(1.0, cut) == :not_yet

      assert Grader.human_band(4.5) == :right and Grader.human_band(3.0) == :partly and
               Grader.human_band(1.0) == :not_yet
    end
  end

  describe "writing cards without a model" do
    @notes """
    A hash table is a data structure that stores key-value pairs in buckets.
    When two keys land in the same bucket, that is called a collision between keys.
    Separate chaining handles collisions by keeping a list in each bucket of the table.
    """

    test "definitions become questions and other sentences become gaps, each with its sentence" do
      cards = Writer.local(@notes)
      assert Enum.any?(cards, &(&1.prompt == "What is a hash table?"))
      assert Enum.any?(cards, &String.starts_with?(&1.prompt, "Fill the gap:"))
      for c <- cards, do: assert(String.contains?(@notes, c.quote))
    end

    test "without Groq, write/2 falls back to the local writer" do
      assert {:local, [%{id: 1} | _]} = Writer.write(@notes, groq: false)
    end

    test "a model's card keeps its quote only if the notes really say it" do
      ok =
        Writer.clean(
          %{"prompt" => "Q?", "answer" => "A", "quote" => "Separate chaining handles collisions"},
          @notes
        )

      assert ok.quote

      made_up =
        Writer.clean(
          %{"prompt" => "Q?", "answer" => "A", "quote" => "Cuckoo hashing uses two tables"},
          @notes
        )

      assert made_up.quote == nil
      assert Writer.clean(%{"prompt" => "", "answer" => "A"}, @notes) == nil
      assert Writer.clean(%{"nonsense" => true}, @notes) == nil
    end
  end

  describe "spaced repetition" do
    defp deck,
      do: Deck.new(for i <- 1..3, do: %{id: i, prompt: "q#{i}", answer: "a#{i}", quote: nil})

    test "a missed card comes back soon; a known card climbs and retires" do
      d = deck()
      assert Deck.next(d).id == 1
      d = Deck.record(d, 1, :not_yet)
      assert Deck.next(d).id == 2
      d = d |> Deck.record(2, :right) |> Deck.record(3, :right)
      assert Deck.next(d).id == 1, "the missed card is due before the known ones"

      d =
        Enum.reduce(1..30, d, fn _, d ->
          if c = Deck.next(d), do: Deck.record(d, c.id, :right), else: d
        end)

      assert Deck.done?(d)
      assert Deck.progress(d).learned == 3
    end

    test "a deck survives the trip through the browser, and junk is refused" do
      d = deck() |> Deck.record(1, :partly)
      json = d |> Deck.dump() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^d} = Deck.load(json)
      assert Deck.load(%{"v" => 1, "turn" => 0, "cards" => [%{"id" => "x"}]}) == :error
      assert Deck.load(%{"anything" => 1}) == :error
    end
  end
end
