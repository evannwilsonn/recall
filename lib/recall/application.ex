defmodule Recall.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The fitted grader and the per-minute limits on calls to Groq.
    Recall.Grader.load!()
    Recall.Limit.setup()

    children = [
      RecallWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:recall, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Recall.PubSub},
      # MiniLM behind a batching server, so concurrent grading shares one compiled model.
      {Nx.Serving,
       serving: Recall.Embedder.serving(batch_size: 4), name: Recall.Embeddings, batch_timeout: 20},
      # Start to serve requests, typically the last entry
      RecallWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Recall.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RecallWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
