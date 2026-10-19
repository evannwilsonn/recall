defmodule Recall.Embedder do
  @moduledoc """
  Sentence embeddings from all-MiniLM-L6-v2 (a 22M-parameter transformer from the
  sentence-transformers project), run in Elixir by Bumblebee and compiled with EXLA. An answer
  becomes 384 numbers; two answers that mean the same thing land close together even when they
  share few words. Answers are short, so the model reads up to 128 word pieces.
  """

  @repo "sentence-transformers/all-MiniLM-L6-v2"
  @seq 128

  def serving(opts \\ []) do
    {:ok, model} = Bumblebee.load_model({:hf, @repo})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @repo})

    Bumblebee.Text.text_embedding(model, tokenizer,
      output_pool: :mean_pooling,
      output_attribute: :hidden_state,
      embedding_processor: :l2_norm,
      compile: [batch_size: Keyword.get(opts, :batch_size, 16), sequence_length: @seq],
      defn_options: [compiler: EXLA]
    )
  end

  @doc "Embeds texts in batches with a serving struct (offline use); returns an `{n, 384}` tensor."
  def embed_all(serving, texts) do
    texts
    |> Enum.chunk_every(16)
    |> Enum.map(fn batch ->
      serving |> Nx.Serving.run(batch) |> Enum.map(& &1.embedding) |> Nx.stack()
    end)
    |> Nx.concatenate()
  end

  @doc "Embeds two texts through the app's running serving; returns their cosine similarity."
  def similarity(a, b) do
    [%{embedding: ea}, %{embedding: eb}] = Nx.Serving.batched_run(Recall.Embeddings, [a, b])
    ea |> Nx.dot(eb) |> Nx.to_number()
  end
end
