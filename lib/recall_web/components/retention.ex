defmodule RecallWeb.Retention do
  @moduledoc """
  The dot-matrix retention charts drawn in the style of Recall's thumbnail: dark dots filled up
  to a sawtooth forgetting curve, faint dots above it, and a thin red curve on top.

  `hero/1` is the illustration on the front page (five reviews over 30 days, each one fading
  slower). `card_column/2` draws one card's slice of the progress chart while studying: the dots
  fill to the card's drawer and fade more slowly the higher the drawer.

  Dots are drawn as zero-length round-capped strokes, so a whole matrix is two short paths.
  """

  @reviews [0, 2, 6, 13, 27]
  @days 30
  @rows 16

  # ── the front-page illustration ──────────────────────────────────────

  @doc "Retention after `t` days with reviews on the days in `@reviews`."
  def r(t) do
    last = @reviews |> Enum.filter(&(&1 <= t)) |> Enum.max()
    k = Enum.find_index(@reviews, &(&1 == last))
    s = 1.6 * :math.pow(2.3, k)
    :math.exp(-(t - last) / s)
  end

  @doc """
  Geometry for the front-page chart: `:wide` has 90 columns like the thumbnail, `:narrow` has
  44 for phones.
  """
  def hero(:wide), do: build(90, 1000, 92, 988, 58, 278)
  def hero(:narrow), do: build(44, 420, 14, 406, 58, 238)

  defp build(cols, w, x0, x1, yt, yb) do
    cw = (x1 - x0) / cols
    rh = (yb - yt) / @rows

    {on, off} =
      for c <- 0..(cols - 1), j <- 0..(@rows - 1), reduce: {[], []} do
        {on, off} ->
          t = c * @days / cols
          dot = {x0 + c * cw + cw / 2, yb - j * rh - rh / 2}
          if (j + 0.5) / @rows <= r(t), do: {[dot | on], off}, else: {on, [dot | off]}
      end

    curve =
      for i <- 0..600 do
        t = i * @days / 600
        {x0 + t / @days * (x1 - x0), yb - r(t) * (yb - yt)}
      end

    %{
      w: w,
      h: yb + 44,
      x0: x0,
      x1: x1,
      yt: yt,
      yb: yb,
      on: dots(on),
      off: dots(off),
      curve: line(curve),
      reviews:
        @reviews
        |> Enum.with_index(1)
        |> Enum.map(fn {d, n} -> %{n: n, x: f(x0 + d / @days * (x1 - x0) + cw / 2)} end),
      ticks: Enum.map(0..@days//5, &%{day: &1, x: f(x0 + &1 / @days * (x1 - x0))})
    }
  end

  # ── one card's column in the study chart ─────────────────────────────

  @cw 10
  @rh 8

  @doc """
  One card's slice of the progress chart, `per` dot columns wide. `box` is the card's drawer
  (4 once learned). Returns the viewBox size and the paths to draw.
  """
  def card_column(box, per) do
    level = min(box, 4) / 4
    # Higher drawers fade slower; a learned card stays full.
    k = Map.get(%{1 => 0.75, 2 => 0.45, 3 => 0.2}, box, 0.0)
    w = per * @cw
    h = @rows * @rh
    at = fn u -> level * :math.exp(-k * u) end

    {on, off} =
      for c <- 0..(per - 1), j <- 0..(@rows - 1), reduce: {[], []} do
        {on, off} ->
          dot = {c * @cw + @cw / 2, h - j * @rh - @rh / 2}

          if (j + 0.5) / @rows <= at.((c + 0.5) / per),
            do: {[dot | on], off},
            else: {on, [dot | off]}
      end

    curve = for i <- 0..24, do: {i / 24 * w, h - at.(i / 24) * (h - 1) - 0.5}

    %{w: w, h: h, on: dots(on), off: dots(off), curve: line(curve)}
  end

  # ── path helpers ─────────────────────────────────────────────────────

  defp dots(points), do: points |> Enum.map(fn {x, y} -> "M#{f(x)} #{f(y)}h0" end) |> Enum.join()

  defp line([{x, y} | rest]),
    do: Enum.join(["M#{f(x)} #{f(y)}" | Enum.map(rest, fn {x, y} -> "L#{f(x)} #{f(y)}" end)])

  defp f(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)
end
