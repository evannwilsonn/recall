defmodule Recall.Mohler do
  @moduledoc """
  The Mohler short-answer grading set (Mohler, Bunescu and Mihalcea, 2011; CC BY 4.0): 2,273
  answers by students in an introductory data structures course, each with the instructor's
  answer and two graders' scores from 0 to 5. It's how Recall checks that its grader agrees
  with people, on questions it was not tuned on.

  Fetched once, in pages, from Hugging Face's dataset viewer API and kept as JSON.
  """

  @api "https://datasets-server.huggingface.co/rows?dataset=nkazi/MohlerASAG&config=cleaned&split=open_ended"

  def path, do: Path.join(File.cwd!(), "priv/data/mohler.json")

  def load do
    unless File.exists?(path()), do: download()

    path()
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn r ->
      %{
        id: r["id"],
        question_id: r["id"] |> String.split(".") |> Enum.take(2) |> Enum.join("."),
        question: clean(r["question"]),
        reference: clean(r["instructor_answer"]),
        answer: clean(r["student_answer"]),
        score: r["score_avg"]
      }
    end)
    |> Enum.reject(&(&1.answer == ""))
  end

  defp download do
    File.mkdir_p!(Path.dirname(path()))

    rows =
      Stream.unfold(0, fn
        nil ->
          nil

        offset ->
          body =
            Req.get!(@api <> "&offset=#{offset}&length=100", retry: :transient, max_retries: 5).body

          next = if offset + 100 < body["num_rows_total"], do: offset + 100
          {Enum.map(body["rows"], & &1["row"]), next}
      end)
      |> Enum.concat()

    File.write!(path(), Jason.encode!(rows))
  end

  defp clean(text),
    do:
      text
      |> to_string()
      |> String.replace("<STOP>", " ")
      |> String.replace("-LRB-", "(")
      |> String.replace("-RRB-", ")")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

  @doc """
  Splits by question, not by answer, so the grader is scored on questions it never saw: about
  60% of questions to fit on, 20% to choose the cut-offs, 20% to test.
  """
  def split(rows) do
    part = fn q ->
      case :erlang.phash2({"recall", q}, 100) do
        n when n < 60 -> :train
        n when n < 80 -> :valid
        _ -> :test
      end
    end

    Enum.group_by(rows, &part.(&1.question_id))
  end
end
