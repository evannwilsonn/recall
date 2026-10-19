defmodule RecallWeb.Router do
  use RecallWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RecallWeb.Layouts, :root}
    plug :protect_from_forgery
    # Hugging Face shows a Space inside an iframe on huggingface.co, so allow that one framer.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "frame-ancestors 'self' https://huggingface.co"
    }

    plug :allow_framing
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RecallWeb do
    pipe_through :browser

    live "/", StudyLive
  end

  defp allow_framing(conn, _opts), do: Plug.Conn.delete_resp_header(conn, "x-frame-options")

  # Other scopes may use custom stacks.
  # scope "/api", RecallWeb do
  #   pipe_through :api
  # end
end
