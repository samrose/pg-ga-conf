defmodule PgGaConf.ResultStore do
  @moduledoc """
  Persistence layer for optimization results.

  Handles observations, sessions, and Sobol cache storage and retrieval.
  """

  import Ecto.Query
  alias PgGaConf.Repo
  alias PgGaConf.Schema.{Observation, Session, SobolCache}
  alias PgGaConf.Fingerprint

  #
  # Observations
  #

  @doc """
  Save an observation (config + score pair) for transfer learning.
  """
  def save_observation(attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    %Observation{}
    |> Observation.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Find similar observations for warm-starting optimization.
  Filters by workload fingerprint similarity or cluster.
  """
  def find_similar_observations(fingerprint_or_cluster, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = Keyword.get(opts, :limit, 20)

    cluster =
      case fingerprint_or_cluster do
        %{} = fp -> Fingerprint.classify(fp)
        cluster when is_atom(cluster) -> cluster
        cluster when is_binary(cluster) -> cluster
      end

    from(o in Observation,
      where: o.workload_cluster == ^to_string(cluster),
      order_by: [desc: :inserted_at],
      limit: ^limit
    )
    |> repo.all()
    |> then(fn observations -> {:ok, observations} end)
  end

  @doc """
  Get the best known config for a workload cluster.
  """
  def best_config_for_cluster(cluster) do
    from(o in Observation,
      where: o.workload_cluster == ^to_string(cluster),
      order_by: [asc: :score],
      limit: 1,
      select: o.config
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      config -> {:ok, atomize_keys(config)}
    end
  end

  #
  # Sessions
  #

  @doc """
  Create a new tuning session.
  """
  def create_session(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a session by ID.
  """
  def get_session(id) do
    Repo.get(Session, id)
  end

  @doc """
  Update a session.
  """
  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update a session by ID.
  """
  def update_session(session_id, attrs, opts \\ []) when is_integer(session_id) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> update_session(session, attrs)
    end
  end

  @doc """
  Get all resumable sessions (paused or crashed running).
  """
  def get_resumable_sessions(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    from(s in Session,
      where: s.status in ["paused", "running"],
      where: not is_nil(s.optimizer_state),
      order_by: [asc: :inserted_at]
    )
    |> repo.all()
  end

  @doc """
  Get active session for a database (running or paused, with checkpoint).
  """
  def get_active_session(db_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    from(s in Session,
      where: s.db_id == ^db_id,
      where: s.status in ["running", "paused"],
      where: not is_nil(s.optimizer_state),
      order_by: [desc: :updated_at],
      limit: 1
    )
    |> repo.one()
    |> case do
      nil -> :not_found
      session -> {:ok, session}
    end
  end

  @doc """
  Get sessions for a specific database.
  """
  def get_sessions_for_db(db_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(s in Session,
      where: s.db_id == ^db_id,
      order_by: [desc: :inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  #
  # Sobol Cache
  #

  @doc """
  Get cached Sobol analysis for a workload cluster.
  """
  def get_cached_sobol(cluster) do
    from(s in SobolCache,
      where: s.fingerprint_cluster == ^to_string(cluster),
      order_by: [desc: :inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Cache Sobol analysis results.
  """
  def cache_sobol(attrs) do
    %SobolCache{}
    |> SobolCache.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Check if Sobol cache exists and is fresh.
  """
  def sobol_cache_valid?(cluster, ttl_ms \\ nil) do
    ttl = ttl_ms || Application.get_env(:pg_ga_conf, :sobol_cache_ttl, :timer.hours(24 * 30))

    case get_cached_sobol(cluster) do
      nil ->
        false

      cache ->
        age_ms = DateTime.diff(DateTime.utc_now(), cache.inserted_at, :millisecond)
        age_ms < ttl
    end
  end

  #
  # Helpers
  #

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, v}
    end)
  rescue
    ArgumentError -> map
  end
end
