defmodule RecallWeb.StudyLiveTest do
  use RecallWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # The tests never call Groq: without a key the local writer makes the cards.
  setup do
    key = System.get_env("GROQ_API_KEY")
    System.delete_env("GROQ_API_KEY")
    on_exit(fn -> if key, do: System.put_env("GROQ_API_KEY", key) end)
  end

  defp start(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#sample") |> render_click()
    view |> form("#notes-form") |> render_submit()
    render_async(view, 10_000)
    view
  end

  test "too few notes asks for more", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("#notes-form", notes: "Too short.") |> render_submit()
    assert has_element?(view, "#error")
  end

  test "sample notes become a deck, and an answer gets graded", %{conn: conn} do
    view = start(conn)
    assert has_element?(view, "#drawers")
    assert has_element?(view, "#card .prompt")

    view
    |> form("#answer-form", answer: "it stores key value pairs in buckets")
    |> render_submit()

    render_async(view, 20_000)
    assert has_element?(view, "#graded .rubber")
    view |> element("#next") |> render_click()
    assert has_element?(view, "#answer-form")
  end

  test "showing the answer and rating yourself moves on", %{conn: conn} do
    view = start(conn)
    view |> element("#reveal") |> render_click()
    assert has_element?(view, "#revealed")
    view |> element("#self-right") |> render_click()
    assert has_element?(view, "#answer-form")
    view |> element("#new") |> render_click()
    assert has_element?(view, "#notes-form")
  end

  test "the page can be framed by Hugging Face", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert get_resp_header(conn, "x-frame-options") == []
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'self' https://huggingface.co"
  end
end
