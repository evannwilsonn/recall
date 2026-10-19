defmodule RecallWeb.StudyLive do
  @moduledoc """
  The whole app on one page. Paste notes, get a drawer of question cards, answer each in your
  own words, and get graded. Cards you miss come back sooner; cards you know move up a drawer and
  retire. The deck is kept in your browser, so you can close the tab and pick up later.
  """
  use RecallWeb, :live_view

  alias Recall.{Deck, Grader, Limit, Writer}

  @sample """
  Hash tables

  A hash table is a data structure that stores key-value pairs in an array of buckets.
  A hash function turns each key into an index, so a lookup can jump straight to the right bucket instead of searching the whole table.
  When two keys land in the same bucket, that is called a collision.
  Separate chaining handles collisions by keeping a small list in each bucket.
  Open addressing handles collisions by probing for the next free slot in the array itself.
  The load factor is the number of stored entries divided by the number of buckets.
  As the load factor grows, collisions become more common and lookups slow down.
  To keep lookups fast, most implementations resize the table, usually doubling it, once the load factor passes a threshold such as 0.75.
  Resizing means every entry must be rehashed into the new, larger array.
  With a good hash function and resizing, insert, delete and lookup take constant time on average.
  In the worst case, when every key collides, a lookup degrades to linear time.
  A good hash function is fast to compute and spreads keys evenly across the buckets.
  """

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Study your notes",
        notes: "",
        deck: nil,
        writer: nil,
        card: nil,
        graded: nil,
        revealed: false,
        writing: false,
        grading: false,
        error: nil,
        answer_key: 0,
        log: [],
        eval: eval()
      )

    socket =
      with true <- connected?(socket),
           saved when is_binary(saved) and byte_size(saved) < 60_000 <-
             get_connect_params(socket)["deck"],
           {:ok, json} <- Jason.decode(saved),
           {:ok, deck} <- Deck.load(json) do
        socket |> assign(deck: deck, writer: json["writer"]) |> pick()
      else
        _ -> socket
      end

    {:ok, socket}
  end

  defp eval do
    with {:ok, body} <- File.read(Path.join(:code.priv_dir(:recall), "model/eval.json")),
         {:ok, eval} <- Jason.decode(body) do
      eval
    else
      _ -> nil
    end
  end

  # ── notes in, cards out ───────────────────────────────────────────────

  @impl true
  def handle_event("notes", %{"notes" => notes}, socket),
    do: {:noreply, assign(socket, notes: notes)}

  def handle_event("sample", _, socket),
    do: {:noreply, assign(socket, notes: String.trim(@sample))}

  def handle_event("write", %{"notes" => notes}, socket) do
    notes = String.trim(notes)

    cond do
      socket.assigns.writing ->
        {:noreply, socket}

      length(Writer.sentences(notes)) < 3 ->
        {:noreply,
         assign(socket,
           notes: notes,
           error: "Paste a bit more: at least a few full sentences of notes."
         )}

      true ->
        # Groq is shared by every visitor, so it gets a per-visitor and an overall budget.
        groq = Limit.allow?({:groq, socket.id}, 3, 60_000) and Limit.allow?(:groq_all, 25, 60_000)

        {:noreply,
         socket
         |> assign(notes: notes, writing: true, error: nil)
         |> start_async(:write, fn -> Writer.write(notes, groq: groq) end)}
    end
  end

  def handle_event("new", _, socket) do
    {:noreply,
     socket
     |> assign(deck: nil, card: nil, graded: nil, revealed: false, writer: nil, log: [])
     |> push_event("save", %{deck: nil})}
  end

  # ── studying ──────────────────────────────────────────────────────────

  def handle_event(
        "answer",
        %{"answer" => answer},
        %{assigns: %{card: card, graded: nil, grading: false}} = socket
      )
      when card != nil do
    answer = String.slice(answer, 0, 1_000)

    {:noreply,
     socket
     |> assign(grading: true)
     |> start_async(:grade, fn -> {answer, Grader.grade(card.answer, answer)} end)}
  end

  def handle_event("reveal", _, socket), do: {:noreply, assign(socket, revealed: true)}

  def handle_event("self", %{"band" => band}, %{assigns: %{card: card}} = socket)
      when card != nil and band in ~w(right partly not_yet) do
    {:noreply, socket |> record(String.to_existing_atom(band)) |> pick()}
  end

  def handle_event("next", _, %{assigns: %{graded: %{band: band}}} = socket),
    do: {:noreply, socket |> record(band) |> pick()}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:write, {:ok, {writer, cards}}, socket) do
    if cards == [] do
      {:noreply,
       assign(socket,
         writing: false,
         error:
           "Couldn't find anything to ask about in those notes. Try notes with full sentences."
       )}
    else
      deck = Deck.new(cards)

      {:noreply,
       socket |> assign(writing: false, deck: deck, writer: to_string(writer)) |> save() |> pick()}
    end
  end

  def handle_async(:write, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket, writing: false, error: "Something went wrong writing the cards. Try again.")}

  def handle_async(:grade, {:ok, {answer, result}}, socket) do
    {:noreply, assign(socket, grading: false, graded: Map.put(result, :answer, answer))}
  end

  def handle_async(:grade, {:exit, _}, socket),
    do: {:noreply, assign(socket, grading: false, error: "The grader didn't answer. Try again.")}

  defp record(socket, band) do
    deck = Deck.record(socket.assigns.deck, socket.assigns.card.id, band)
    entry = %{turn: deck.turn, id: socket.assigns.card.id, band: band}

    socket
    |> assign(deck: deck, log: Enum.take([entry | socket.assigns.log], 9))
    |> save()
  end

  defp pick(socket) do
    assign(socket,
      card: Deck.next(socket.assigns.deck),
      graded: nil,
      revealed: false,
      error: nil,
      answer_key: socket.assigns.answer_key + 1
    )
  end

  defp save(socket),
    do:
      push_event(socket, "save", %{
        deck: Map.put(Deck.dump(socket.assigns.deck), :writer, socket.assigns.writer)
      })

  # ── view ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="store" phx-hook="DeckStore"></div>
      <main class="desk">
        <header class="top">
          <a href="/" class="brand"><span class="drawer-pull" aria-hidden="true"></span>Recall</a>
          <span class="tag-line">a card catalogue for your notes</span>
          <button
            id="theme"
            class="lamp"
            type="button"
            phx-click={JS.dispatch("phx:toggle-theme")}
            aria-label="Switch between light and dark"
          >
            Lamp
          </button>
        </header>

        <%= if @deck == nil do %>
          <section class="intake">
            <div class="intro">
              <p class="call-no mono">QA 76.9 · R43 · 2026</p>
              <h1>Study what you actually wrote down.</h1>
              <p>
                Paste notes from a lecture or a chapter. Recall files them as question cards, you
                answer in your own words, and it grades you against the notes.
              </p>
              <ol class="steps">
                <li class="step">
                  <span class="mono">No. 1</span><b>Paste your notes</b><span>Llama on Groq writes questions from them, and only them.</span>
                </li>
                <li class="step">
                  <span class="mono">No. 2</span><b>Answer in your words</b><span>MiniLM, running in Elixir, grades the meaning.</span>
                </li>
                <li class="step">
                  <span class="mono">No. 3</span><b>Misses come back</b><span>Right answers move up a drawer until they retire.</span>
                </li>
              </ol>
            </div>
            <div class="cabinet">
              <div class="drawer-front" aria-hidden="true">
                <span class="label-holder"><span>Notes · unfiled</span></span>
                <span class="pull"></span>
              </div>
              <form id="notes-form" class="card notes" phx-change="notes" phx-submit="write">
                <label for="notes-text" class="label">Your notes</label>
                <textarea
                  id="notes-text"
                  name="notes"
                  maxlength={Writer.max_notes()}
                  rows="12"
                  placeholder="Paste a page or two of notes…"
                  phx-debounce="400"
                >{@notes}</textarea>
                <div class="row">
                  <button id="sample" type="button" class="ghost" phx-click="sample">
                    Use sample notes (hash tables)
                  </button>
                  <span class="count mono">{String.length(@notes)} / {Writer.max_notes()}</span>
                </div>
                <p :if={@error} id="error" class="error" role="alert">{@error}</p>
                <button id="write" class="stamp-btn" disabled={@writing}>
                  {if @writing, do: "Writing cards…", else: "File my cards"}
                </button>
              </form>
            </div>
          </section>
        <% else %>
          <section class="study">
            <.drawers deck={@deck} />
            <div class="desk-row">
              <div class="card-col">
                <%= if @card do %>
                  <article id="card" class="card index-card">
                    <div class="card-head">
                      <span class="mono">No. {@card.id}</span>
                      <span class="mono">drawer {@card.box} · seen {@card.seen}</span>
                    </div>
                    <h2 class="prompt">{@card.prompt}</h2>

                    <%= cond do %>
                      <% @graded -> %>
                        <div id="graded" class={"result b-#{@graded.band}"}>
                          <span class="rubber">{band_label(@graded.band)}</span>
                          <p class="yours">
                            <span class="label">You wrote</span> {if @graded.answer == "",
                              do: "(nothing)",
                              else: @graded.answer}
                          </p>
                          <p class="model">
                            <span class="label">From your notes</span> {@card.answer}
                          </p>
                          <p :if={@graded.missing != [] and @graded.band != :right} class="missing">
                            <span class="label">Words you left out</span>
                            <span :for={w <- @graded.missing} class="chip">{w}</span>
                          </p>
                          <p class="mono score">
                            score {:erlang.float_to_binary(@graded.score, decimals: 1)} / 5 · meaning {pct(
                              @graded.similarity
                            )} · words {pct(@graded.coverage)}
                          </p>
                          <div class="row">
                            <button
                              id="next"
                              class="stamp-btn"
                              phx-click="next"
                              phx-mounted={JS.focus()}
                            >Next card</button>
                            <button
                              :if={@graded.band != :right}
                              id="overrule"
                              class="ghost"
                              phx-click="self"
                              phx-value-band="right"
                            >
                              I was right
                            </button>
                          </div>
                        </div>
                      <% @revealed -> %>
                        <div id="revealed" class="result">
                          <p class="model">
                            <span class="label">From your notes</span> {@card.answer}
                          </p>
                          <p class="label">How did you do?</p>
                          <div class="row self">
                            <button
                              id="self-right"
                              class="ghost"
                              phx-click="self"
                              phx-value-band="right"
                            >Knew it</button>
                            <button
                              id="self-partly"
                              class="ghost"
                              phx-click="self"
                              phx-value-band="partly"
                            >Partly</button>
                            <button
                              id="self-not"
                              class="ghost"
                              phx-click="self"
                              phx-value-band="not_yet"
                            >Not yet</button>
                          </div>
                        </div>
                      <% true -> %>
                        <form id="answer-form" phx-submit="answer">
                          <label for={"answer-#{@answer_key}"} class="label">Your answer</label>
                          <textarea
                            id={"answer-#{@answer_key}"}
                            name="answer"
                            rows="3"
                            maxlength="1000"
                            placeholder="In your own words…"
                            phx-mounted={JS.focus()}
                          ></textarea>
                          <div class="row">
                            <button id="check" class="stamp-btn" disabled={@grading}>{if @grading,
                              do: "Grading…",
                              else: "Check my answer"}</button>
                            <button id="reveal" type="button" class="ghost" phx-click="reveal">Just show me</button>
                          </div>
                        </form>
                    <% end %>

                    <blockquote :if={@card.quote && (@graded || @revealed)} class="quote">
                      “{@card.quote}”
                    </blockquote>
                  </article>
                <% else %>
                  <article id="done" class="card index-card done">
                    <span class="rubber">Learned</span>
                    <h2 class="prompt">
                      All {length(@deck.cards)} cards learned in {@deck.turn} answers.
                    </h2>
                    <p>
                      Each card had to be answered right three times, with other cards in between, to retire.
                    </p>
                  </article>
                <% end %>
              </div>
              <aside id="slip" class="slip" aria-label="Date due slip: your answers so far">
                <span class="slip-pocket" aria-hidden="true"></span>
                <h3 class="mono">Date due</h3>
                <ol>
                  <li :for={e <- @log} class={"s-#{e.band}"}>
                    <span class="mono">turn {e.turn}</span>
                    <span class="mono">No. {e.id}</span>
                    <span class="stamp-mini">{band_label(e.band)}</span>
                  </li>
                  <li :if={@log == []} class="blank mono">no answers yet</li>
                </ol>
              </aside>
            </div>

            <div class="row foot-row">
              <span class="writer mono">{writer_label(@writer)}</span>
              <button id="new" class="ghost" phx-click="new">New notes</button>
            </div>
            <p :if={@error} class="error" role="alert">{@error}</p>
          </section>
        <% end %>

        <section :if={@eval} id="how" class="how">
          <h2>How the grading works</h2>
          <p>
            Your answer and the answer from your notes each go through MiniLM, a small sentence
            model running in Elixir, which places sentences with the same meaning close together.
            That closeness, the share of key words you used and your answer's length are combined
            into a score out of 5 by a line fitted to answers that teaching assistants graded by
            hand ({@eval["dataset"]["answers"]} of them, the Mohler set, from a data structures
            course). Scored on questions it never saw:
          </p>
          <table class="ledger">
            <thead>
              <tr>
                <th>Grader</th><th>Off by (RMSE)</th><th>Same band as people</th><th>Balanced</th><th>
                  Correlation
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={m <- @eval["models"]}
                class={m["name"] == @eval["shipped"]["name"] && "shipped"}
              >
                <td>{m["name"]}{if m["name"] == @eval["shipped"]["name"], do: " (used)"}</td>
                <td class="mono">{f2(m["test"]["rmse"])}</td>
                <td class="mono">{pct(m["test"]["band_accuracy"])}</td>
                <td class="mono">{pct(m["test"]["balanced"])}</td>
                <td class="mono">{f2(m["test"]["pearson"])}</td>
              </tr>
            </tbody>
          </table>
          <p class="fine">
            Bands: got it is 4 or more out of 5 from the people grading, partly 2.5 to 4, not yet
            below that. Most answers in the set are good ones, so always saying "got it" already
            matches people 69% of the time; "balanced" counts each band equally, and that is what the
            cut-offs were tuned for, so a wrong answer is rarely waved through. The price is that
            some good answers get "partly" or "not yet", which is why there's an "I was right" button. The grader can be fooled by an answer with the right words in a wrong
            sentence, so "Just show me" and your own judgment are always there.
          </p>
        </section>

        <footer class="foot">
          Built by Evan Wilson in Elixir, Phoenix LiveView, Nx and Bumblebee. Grader tested on the
          Mohler short-answer set (Mohler, Bunescu &amp; Mihalcea 2011, CC BY 4.0). Notes you paste
          go to Groq only to write the questions, and Recall doesn't store them.
        </footer>
      </main>
    </Layouts.app>
    """
  end

  attr :deck, Deck, required: true

  defp drawers(assigns) do
    assigns = assign(assigns, p: Deck.progress(assigns.deck))

    ~H"""
    <div id="drawers" class="drawers" aria-label="Progress">
      <div
        :for={
          {label, n} <- [
            {"Drawer 1", @p.box1},
            {"Drawer 2", @p.box2},
            {"Drawer 3", @p.box3},
            {"Learned", @p.learned}
          ]
        }
        class="drawer"
      >
        <span class="plate">{label}</span>
        <span class="mono n">{n}</span>
        <span
          class="fill"
          style={"width: #{if @p.total > 0, do: round(n / @p.total * 100), else: 0}%"}
        ></span>
      </div>
    </div>
    """
  end

  defp band_label(:right), do: "Got it"
  defp band_label(:partly), do: "Partly"
  defp band_label(:not_yet), do: "Not yet"

  defp writer_label("groq"), do: "questions written by Llama 3.3 on Groq, from your notes"
  defp writer_label(_), do: "questions made from your notes' own sentences"

  defp pct(nil), do: "–"
  defp pct(x), do: "#{round(x * 100)}%"
  defp f2(nil), do: "–"
  defp f2(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
end
