defmodule Pachka.StatusTable do
  use GenServer

  @type status :: :available | :overloaded

  @spec get_status(atom()) :: status()
  def get_status(server_name) do
    :ets.lookup_element(__MODULE__, server_name, 2)
  end

  @spec set_status(atom(), status()) :: :ok
  def set_status(server_name, status) do
    :ets.insert(__MODULE__, {server_name, status})
    :ok
  end

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_init_arg) do
    GenServer.start_link(__MODULE__, nil)
  end

  @impl true
  def init(_init_arg) do
    _ = :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])

    {:ok, nil}
  end
end
