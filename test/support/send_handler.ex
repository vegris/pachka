defmodule Test.Support.SendHandler do
  @behaviour Pachka.Handler

  @impl true
  def send_batch(messages) do
    if blocking?() do
      Process.sleep(:infinity)
    else
      send(receiver_pid(), {:batch, messages})
    end

    :ok
  end

  def set_receiver_pid(pid), do: put_option(:receiver_pid, pid)
  def set_blocking?(blocking), do: put_option(:blocking?, blocking)

  def clear, do: Application.delete_env(:pachka, __MODULE__)

  defp receiver_pid, do: fetch_option!(:receiver_pid)
  defp blocking?, do: fetch_option!(:blocking?)

  defp fetch_option!(name) do
    :pachka
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(name)
  end

  @defaults [blocking?: false]

  defp put_option(name, value) do
    :pachka
    |> Application.get_env(__MODULE__, @defaults)
    |> Keyword.put(name, value)
    |> then(&Application.put_env(:pachka, __MODULE__, &1))
  end
end
