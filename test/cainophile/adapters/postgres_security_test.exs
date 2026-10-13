defmodule Cainophile.Adapters.PostgresSecurityTest do
  use ExUnit.Case, async: true

  @behaviour Cainophile.Adapters.Postgres.AdapterBehaviour

  import ExUnit.CaptureLog

  alias Cainophile.Adapters.Postgres
  alias Cainophile.Adapters.Postgres.State

  @password "cainophile-dummy-password"

  @impl true
  def init(config) do
    {:ok, %State{config: config, connection: Keyword.fetch!(config, :cleanup_receiver)}}
  end

  @impl true
  def cleanup(receiver) do
    send(receiver, :connection_cleaned_up)
    :ok
  end

  @impl true
  def acknowledge_lsn(_connection, _lsn), do: :ok

  test "static passwords are hidden before the GenServer stores its configuration" do
    pid = start_postgres(%{password: @password})
    state = :sys.get_state(pid)
    password = state.config[:epgsql].password

    assert is_function(password, 0)
    assert password.() == @password
    refute inspect(state) =~ @password
    refute inspect(:sys.get_status(pid)) =~ @password
  end

  test "existing password callbacks are preserved and are not evaluated at startup" do
    receiver = self()

    password = fn ->
      send(receiver, :password_requested)
      @password
    end

    pid = start_postgres(%{password: password})
    state = :sys.get_state(pid)

    assert state.config[:epgsql].password == password
    refute_received :password_requested
  end

  test "EXIT cleanup redacts nested passwords without changing the exit reason" do
    state = %State{
      config: [postgres_adapter: __MODULE__, epgsql: %{password: @password, username: "dummy"}],
      connection: self()
    }

    assert {:stop, :econnreset, stopped_state} =
             Postgres.handle_info({:EXIT, self(), :econnreset}, state)

    assert_received :connection_cleaned_up
    assert stopped_state.connection == nil
    assert stopped_state.config[:epgsql] == %{username: "dummy"}
    refute inspect(stopped_state) =~ @password
  end

  test "EXIT cleanup also accepts configuration without epgsql options" do
    state = %State{config: [postgres_adapter: __MODULE__]}
    assert {:stop, :normal, _state} = Postgres.handle_info({:EXIT, self(), :normal}, state)
  end

  test "status formatting redacts raw passwords without mutating live state" do
    state = %State{config: [epgsql: %{password: @password, username: "dummy"}]}

    for reason <- [:normal, :terminate] do
      refute inspect(Postgres.format_status(reason, [[], state])) =~ @password
    end

    assert state.config[:epgsql].password == @password
  end

  test "unexpected callback crashes do not log the password" do
    pid = start_postgres(%{password: @password})
    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        send(pid, {:epgsql, self(), {:x_log_data, 0, 0, <<>>}})
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)

    assert log =~ "terminating"
    refute log =~ @password
    assert_received :connection_cleaned_up
  end

  defp start_postgres(epgsql) do
    start_supervised!(
      {Postgres, postgres_adapter: __MODULE__, epgsql: epgsql, cleanup_receiver: self()},
      restart: :temporary
    )
  end
end

