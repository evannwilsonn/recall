defmodule Recall.Deck do
  @moduledoc """
  Spaced repetition within a study session, Leitner style. Every card starts in box 1. Get it
  right and it moves up a box and comes back later; get it partly and it stays put; miss it and
  it goes back to box 1 and comes back soon. A card right in box 3 is learned and retires.

  Time is counted in turns, not minutes: a card "due in 4" comes back after four other answers.
  """

  @gaps %{1 => 2, 2 => 4, 3 => 7}
  @soon 2

  defstruct cards: [], turn: 0

  @doc "A deck of cards, each `%{id, prompt, answer, quote}`."
  def new(cards),
    do: %__MODULE__{cards: Enum.map(cards, &Map.merge(&1, %{box: 1, due: 0, seen: 0, last: nil}))}

  @doc "The next card to study, or nil when every card is learned."
  def next(%__MODULE__{cards: cards, turn: turn}) do
    cards
    |> Enum.reject(&(&1.box > 3))
    |> Enum.sort_by(&{max(&1.due - turn, 0), &1.box, &1.due, &1.id})
    |> List.first()
  end

  @doc "Records how an answer to card `id` went: `:right`, `:partly` or `:not_yet`."
  def record(%__MODULE__{} = deck, id, band) when band in [:right, :partly, :not_yet] do
    turn = deck.turn + 1

    cards =
      Enum.map(deck.cards, fn
        %{id: ^id} = c ->
          box =
            case band do
              :right -> c.box + 1
              :partly -> c.box
              :not_yet -> 1
            end

          gap = if band == :right, do: Map.get(@gaps, box, 0), else: @soon
          %{c | box: box, due: turn + gap, seen: c.seen + 1, last: band}

        c ->
          c
      end)

    %{deck | cards: cards, turn: turn}
  end

  @doc "How many cards sit in each box, and how many are learned."
  def progress(%__MODULE__{cards: cards}) do
    counts = Enum.frequencies_by(cards, &min(&1.box, 4))

    %{
      box1: counts[1] || 0,
      box2: counts[2] || 0,
      box3: counts[3] || 0,
      learned: counts[4] || 0,
      total: length(cards)
    }
  end

  def done?(deck), do: next(deck) == nil

  # ── saving in the browser ─────────────────────────────────────────────

  @doc "A plain map for the browser to keep between visits."
  def dump(%__MODULE__{} = deck),
    do: %{
      v: 1,
      turn: deck.turn,
      cards: Enum.map(deck.cards, &Map.update!(&1, :last, fn l -> l && to_string(l) end))
    }

  @doc "Rebuilds a deck the browser kept. Anything malformed gives `:error`."
  def load(%{"v" => 1, "turn" => turn, "cards" => cards})
      when is_integer(turn) and is_list(cards) and length(cards) in 1..12 do
    cards = Enum.map(cards, &card/1)
    if Enum.all?(cards), do: {:ok, %__MODULE__{cards: cards, turn: turn}}, else: :error
  end

  def load(_), do: :error

  defp card(
         %{"id" => id, "prompt" => p, "answer" => a, "box" => box, "due" => due, "seen" => seen} =
           c
       )
       when is_integer(id) and is_binary(p) and is_binary(a) and box in 1..4 and is_integer(due) and
              is_integer(seen) and byte_size(p) <= 1_200 and byte_size(a) <= 1_600 do
    quote = if is_binary(c["quote"]) and byte_size(c["quote"]) <= 2_000, do: c["quote"]

    last =
      case c["last"] do
        "right" -> :right
        "partly" -> :partly
        "not_yet" -> :not_yet
        _ -> nil
      end

    %{id: id, prompt: p, answer: a, quote: quote, box: box, due: due, seen: seen, last: last}
  end

  defp card(_), do: nil
end
