defmodule Mix.Tasks.Recall.Eval do
  @shortdoc "Fits and scores the answer grader on the Mohler set; writes priv/model/grader.json"
  @moduledoc """
      mix recall.eval

  Fits four graders on the Mohler questions set aside for fitting, picks the one with the
  smallest error on the validation questions, chooses its band cut-offs there too, and scores
  every grader once on the test questions:

    * the average score, for everyone (the floor)
    * word coverage alone
    * MiniLM meaning alone
    * meaning, coverage and length together
  """
  use Mix.Task

  alias Recall.{Embedder, Grader, Mohler}

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started([:req, :exla, :bumblebee])

    rows = Mohler.load()
    parts = Mohler.split(rows)
    questions = fn rs -> rs |> Enum.uniq_by(& &1.question_id) |> length() end
    info("#{length(rows)} graded answers to #{questions.(rows)} questions")

    for p <- [:train, :valid, :test],
        do: info("  #{p}: #{length(parts[p])} answers, #{questions.(parts[p])} questions")

    info("embedding answers with MiniLM")
    serving = Embedder.serving(batch_size: 16)
    texts = rows |> Enum.flat_map(&[&1.reference, &1.answer]) |> Enum.uniq()
    emb = Embedder.embed_all(serving, texts)
    index = texts |> Enum.with_index() |> Map.new()
    sim = fn r -> Nx.dot(emb[index[r.reference]], emb[index[r.answer]]) |> Nx.to_number() end

    feats =
      Map.new(rows, fn r ->
        {r.id, Grader.features(sim.(r), Grader.overlap(r.reference, r.answer))}
      end)

    take = fn row, cols -> Enum.map(cols, &Enum.at(feats[row.id], &1)) end
    scores = fn part -> Enum.map(parts[part], & &1.score) end
    mean = Enum.sum(scores.(:train)) / length(parts.train)

    candidates = [
      {"average score", nil},
      {"word coverage", [0, 2]},
      {"MiniLM meaning", [0, 1]},
      {"meaning + coverage + length", [0, 1, 2, 3]}
    ]

    results =
      for {name, cols} <- candidates do
        {weights, predict} =
          case cols do
            nil ->
              {[mean], fn _ -> mean end}

            cols ->
              w = Grader.fit(Enum.map(parts.train, &take.(&1, cols)), scores.(:train))
              {w, fn r -> Grader.predict(w, take.(r, cols)) end}
          end

        valid = Enum.map(parts.valid, predict)
        cutoffs = best_cutoffs(valid, scores.(:valid))
        test = Enum.map(parts.test, predict)

        %{
          name: name,
          cols: cols,
          weights: weights,
          cutoffs: cutoffs,
          valid_rmse: rmse(valid, scores.(:valid)),
          test: %{
            rmse: rmse(test, scores.(:test)),
            pearson: pearson(test, scores.(:test)),
            band_accuracy: band_accuracy(test, scores.(:test), cutoffs),
            balanced: balanced(test, scores.(:test), cutoffs)
          },
          predicted: test
        }
      end

    shipped = results |> tl() |> Enum.min_by(& &1.valid_rmse)
    info("shipping: #{shipped.name}")

    for r <- results do
      info(
        String.pad_trailing(r.name, 30) <>
          "valid RMSE #{f(r.valid_rmse)}   test RMSE #{f(r.test.rmse)}  r #{f(r.test.pearson)}  bands #{pct(r.test.band_accuracy)}  balanced #{pct(r.test.balanced)}"
      )
    end

    # The app always computes all four features; the ones the shipped grader doesn't use get 0.
    weights =
      for i <- 0..3 do
        case Enum.find_index(shipped.cols, &(&1 == i)) do
          nil -> 0.0
          j -> Enum.at(shipped.weights, j)
        end
      end

    cutoffs = %{"partly" => elem(shipped.cutoffs, 0), "right" => elem(shipped.cutoffs, 1)}
    bands = [:right, :partly, :not_yet]

    confusion =
      Enum.zip(shipped.predicted, scores.(:test))
      |> Enum.frequencies_by(fn {p, h} -> {Grader.human_band(h), Grader.band(p, cutoffs)} end)

    examples =
      parts.test
      |> Enum.zip(shipped.predicted)
      |> Enum.sort_by(fn {r, _} -> :erlang.phash2(r.id) end)
      |> Enum.take(6)
      |> Enum.map(fn {r, p} ->
        %{
          question: r.question,
          reference: r.reference,
          answer: r.answer,
          people: r.score,
          grader: Float.round(p, 2)
        }
      end)

    File.mkdir_p!("priv/model")
    File.mkdir_p!("results")

    File.write!(
      "priv/model/grader.json",
      Jason.encode!(
        %{
          method: shipped.name,
          features: ["bias", "meaning", "coverage", "length"],
          weights: weights,
          cutoffs: cutoffs
        },
        pretty: true
      )
    )

    eval = %{
      dataset: %{
        name: "Mohler short-answer grading (2011), CC BY 4.0",
        answers: length(rows),
        questions: questions.(rows),
        split: Map.new([:train, :valid, :test], &{&1, length(parts[&1])}),
        human_bands: "got it: 4 or more of 5; partly: 2.5 up to 4; not yet: under 2.5"
      },
      shipped: %{name: shipped.name, weights: weights, cutoffs: cutoffs},
      models: Enum.map(results, &Map.take(&1, [:name, :valid_rmse, :test])),
      confusion:
        for(
          h <- bands,
          do: %{
            people: h,
            grader: for(g <- bands, into: %{}, do: {g, Map.get(confusion, {h, g}, 0)})
          }
        ),
      examples: examples
    }

    File.write!("results/eval.json", Jason.encode!(eval, pretty: true))
    File.cp!("results/eval.json", "priv/model/eval.json")
  end

  # The cut-offs that best match people's bands on the validation questions, with each band
  # counting equally. Most Mohler answers are good ones, so plain accuracy would be best served by
  # calling nearly everything "got it", which is the one thing a study tool must not do.
  defp best_cutoffs(pred, human) do
    grid = for i <- 0..100, do: i * 0.05

    for lo <- grid, hi <- grid, hi > lo, reduce: {{2.5, 4.0}, -1} do
      {best, acc} ->
        a = balanced(pred, human, {lo, hi})
        if a > acc, do: {{lo, hi}, a}, else: {best, acc}
    end
    |> elem(0)
  end

  defp band_accuracy(pred, human, {lo, hi}) do
    cut = %{"partly" => lo, "right" => hi}

    Enum.zip(pred, human)
    |> Enum.count(fn {p, h} -> Grader.band(p, cut) == Grader.human_band(h) end)
    |> Kernel./(length(pred))
  end

  # The average, over the three bands, of the share of answers in that band the grader got right.
  defp balanced(pred, human, {lo, hi}) do
    cut = %{"partly" => lo, "right" => hi}

    Enum.zip(pred, human)
    |> Enum.group_by(fn {_, h} -> Grader.human_band(h) end)
    |> Enum.map(fn {band, pairs} ->
      Enum.count(pairs, fn {p, _} -> Grader.band(p, cut) == band end) / length(pairs)
    end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end

  defp rmse(p, y),
    do:
      :math.sqrt(
        Enum.zip(p, y)
        |> Enum.map(fn {a, b} -> (a - b) ** 2 end)
        |> Enum.sum()
        |> Kernel./(length(p))
      )

  defp pearson(p, y) do
    n = length(p)
    mp = Enum.sum(p) / n
    my = Enum.sum(y) / n
    cov = Enum.zip(p, y) |> Enum.map(fn {a, b} -> (a - mp) * (b - my) end) |> Enum.sum()
    sp = p |> Enum.map(&((&1 - mp) ** 2)) |> Enum.sum() |> :math.sqrt()
    sy = y |> Enum.map(&((&1 - my) ** 2)) |> Enum.sum() |> :math.sqrt()
    if sp == 0 or sy == 0, do: 0.0, else: cov / (sp * sy)
  end

  defp f(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)
  defp pct(x), do: "#{Float.round(x * 100, 1)}%"
  defp info(msg), do: Mix.shell().info(msg)
end
