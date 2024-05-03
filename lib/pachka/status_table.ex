defmodule Pachka.StatusTable do
  @type status :: :available | :overloaded

  @spec create() :: :ok
  def create do
    _ = :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])
    :ok
  end

  @spec get_status(atom()) :: status()
  def get_status(server_name) do
    :ets.lookup_element(__MODULE__, server_name, 2)
  end

  @spec set_status(atom(), status()) :: :ok
  def set_status(server_name, status) do
    :ets.insert(__MODULE__, {server_name, status})
    :ok
  end
end
