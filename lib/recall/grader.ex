defmodule Recall.Grader do
  @moduledoc """
  Grades a written answer against the answer from your notes, on the 0 to 5 scale teaching
  assistants used for the Mohler set, then puts it in one of three bands: got it, partly, not yet.

  Three things go in:

    * meaning: the cosine similarity of the two answers' MiniLM embeddings
    * coverage: the share of the reference answer's content words that appear in yours
      (after trimming plural and tense endings)
    * length: how long yours is next to the reference, capped at twice as long

  A straight line through those three, fitted by least squares on the Mohler questions set
  aside for fitting, turns them into a score. The cut-offs between bands are chosen on a second
  set of questions; `mix recall.eval` reports how it does on a third. The fitted numbers live in
  `priv/model/grader.json`.
  """

  @stop ~w(a an the of to in on at for from by with and or but if then than as is are was were be been being it its this that these those there their they them we you your i he she his her our not no do does did done can could will would should may might must so such into over under about which what when where who whom how why also very more most other some any each all both only own same just has have had having)

  @doc "The words that carry meaning: lower-cased, stop words dropped, endings trimmed."
  def content_words(text) do
    text
    |> String.downcase()
    |> then(&Regex.scan(~r/[a-z0-9]+/u, &1))
    |> List.flatten()
    |> Enum.reject(&(&1 in @stop or String.length(&1) < 2))
    |> Enum.map(&stem/1)
  end

  # Crude, but enough to match "pointers" with "pointer" and "sorted" with "sorting".
  defp stem(w) do
    cond do
      String.length(w) > 5 and String.ends_with?(w, "ies") ->
        String.slice(w, 0..-4//1) <> "y"

      String.length(w) > 5 and String.ends_with?(w, "ing") ->
        String.slice(w, 0..-4//1)

      String.length(w) > 4 and String.ends_with?(w, "ed") ->
        String.slice(w, 0..-3//1)

      String.length(w) > 4 and String.ends_with?(w, "es") ->
        String.slice(w, 0..-3//1)

      String.length(w) > 3 and String.ends_with?(w, "s") and not String.ends_with?(w, "ss") ->
        String.slice(w, 0..-2//1)

      true ->
        w
    end
  end

  @doc "Coverage, length and the reference words missing from the answer."
  def overlap(reference, answer) do
    ref = Enum.uniq(content_words(reference))
    ans = MapSet.new(content_words(answer))
    hits = Enum.count(ref, &MapSet.member?(ans, &1))
    coverage = if ref == [], do: 0.0, else: hits / length(ref)
    len = min(String.length(answer) / max(String.length(reference), 1), 2.0) / 2
    # Show missing words as the notes spell them, not as their trimmed stems.
    spelled =
      Regex.scan(~r/[a-z0-9]+/u, String.downcase(reference))
      |> List.flatten()
      |> Enum.reduce(%{}, fn w, acc -> Map.put_new(acc, stem(w), w) end)

    missing = for w <- ref, not MapSet.member?(ans, w), do: Map.get(spelled, w, w)
    %{coverage: coverage, length: len, missing: missing}
  end

  @doc "The feature row for one answer: `[1, meaning, coverage, length]`."
  def features(similarity, %{coverage: c, length: l}), do: [1.0, similarity, c, l]

  @doc "Least-squares weights for rows of features and their scores."
  def fit(rows, scores) do
    x = Nx.tensor(rows, type: :f64, backend: Nx.BinaryBackend)
    y = Nx.tensor(scores, type: :f64, backend: Nx.BinaryBackend)
    # A touch of ridge keeps the solve stable when two features move together.
    xt = Nx.transpose(x)

    a =
      Nx.dot(xt, x)
      |> Nx.add(
        Nx.multiply(Nx.eye(Nx.axis_size(x, 1), type: :f64, backend: Nx.BinaryBackend), 1.0e-3)
      )

    a |> Nx.LinAlg.solve(Nx.dot(xt, y)) |> Nx.to_list()
  end

  def predict(weights, row),
    do:
      weights
      |> Enum.zip(row)
      |> Enum.map(fn {w, x} -> w * x end)
      |> Enum.sum()
      |> min(5.0)
      |> max(0.0)

  def band(score, %{"partly" => lo, "right" => hi}) do
    cond do
      score >= hi -> :right
      score >= lo -> :partly
      true -> :not_yet
    end
  end

  @doc "The band people gave, from Mohler's 0 to 5 score."
  def human_band(score) when score >= 4.0, do: :right
  def human_band(score) when score >= 2.5, do: :partly
  def human_band(_), do: :not_yet

  # ── at run time ───────────────────────────────────────────────────────

  def model_path, do: Path.join(:code.priv_dir(:recall), "model/grader.json")

  def load! do
    model = model_path() |> File.read!() |> Jason.decode!()
    :persistent_term.put(__MODULE__, model)
  end

  @doc """
  Grades `answer` against `reference`: `%{score, band, similarity, coverage, missing}`. An empty
  answer is "not yet" without asking the model.
  """
  def grade(reference, answer) do
    answer = String.trim(answer)

    if content_words(answer) == [] do
      %{
        score: 0.0,
        band: :not_yet,
        similarity: 0.0,
        coverage: 0.0,
        missing: Enum.uniq(content_words(reference)) |> Enum.take(5)
      }
    else
      model = :persistent_term.get(__MODULE__)
      sim = Recall.Embedder.similarity(reference, answer)
      o = overlap(reference, answer)
      score = predict(model["weights"], features(sim, o))

      %{
        score: score,
        band: band(score, model["cutoffs"]),
        similarity: sim,
        coverage: o.coverage,
        missing: Enum.take(o.missing, 5)
      }
    end
  end
end
