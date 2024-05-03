defmodule Pachka.StatusTable.Holder do
  use GenServer

  def start_link([]) do
    GenServer.start_link(__MODULE__, nil)
  end

  @impl true
  def init(nil) do
    Pachka.StatusTable.create()

    {:ok, nil}
  end
end
