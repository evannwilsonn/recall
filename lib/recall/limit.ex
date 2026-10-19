defmodule Recall.Limit do
  @moduledoc """
  Fixed-window counters in ETS, so one visitor (or everyone together) can't burn through the
  Groq quota. `allow?("groq:all", 20, 60_000)` lets 20 calls through per minute.
  """

  @table :recall_limits

  def setup, do: :ets.new(@table, [:named_table, :public, write_concurrency: true])

  def allow?(key, limit, window_ms) do
    window = div(System.monotonic_time(:millisecond), window_ms)

    case :ets.lookup(@table, key) do
      [{^key, ^window, count}] when count >= limit ->
        false

      [{^key, ^window, _}] ->
        :ets.update_counter(@table, key, {3, 1})
        true

      _ ->
        :ets.insert(@table, {key, window, 1})
        true
    end
  end
end
