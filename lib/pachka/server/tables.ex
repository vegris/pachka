defmodule Pachka.Server.Tables do
  @type t :: {:ets.tid(), :ets.tid()}

  # Use negative integer as counter key
  # so that counter value will be at the head of the list after sorting for quick removal
  @counter_key -1

  @spec create(atom()) :: t()
  def create(name) do
    tables =
      1..2
      |> Enum.map(fn i ->
        :"#{name}.ExportTable#{i}"
        |> :ets.new([:set, :public, write_concurrency: true])
        |> tap(&reset_counter/1)
      end)
      |> List.to_tuple()

    _ = :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(name, {:current_table, elem(tables, 0), :available})

    tables
  end

  @spec write_message(atom(), Pachka.message()) :: :ok | {:error, :overloaded}
  def write_message(name, message) do
    [{:current_table, table, status}] = :ets.lookup(name, :current_table)

    case status do
      :available ->
        index = :ets.update_counter(table, @counter_key, 1)
        :ets.insert(table, {index, message})

        :ok

      :overloaded ->
        {:error, :overloaded}
    end
  end

  @spec reset_table(:ets.tid()) :: :ok
  def reset_table(table) do
    _table =
      table
      |> tap(&:ets.delete_all_objects/1)
      |> tap(&reset_counter/1)

    :ok
  end

  @spec to_list(:ets.tid()) :: [Pachka.message()]
  def to_list(table) do
    table
    |> :ets.tab2list()
    |> List.keysort(0)
    # remove counter value
    |> tl()
    |> Enum.map(fn {_index, value} -> value end)
  end

  @spec active_size(atom()) :: integer()
  def active_size(name) do
    size =
      name
      |> active_table()
      |> :ets.info(:size)
      # adjust for counter value
      |> Kernel.-(1)

    # make Dialyzer happy
    true = is_integer(size)

    size
  end

  @spec switch_active(atom(), t()) :: :ets.tid()
  def switch_active(name, tables) do
    active_table = active_table(name)

    {table_1, table_2} = tables

    inactive_table =
      case active_table do
        ^table_1 -> table_2
        ^table_2 -> table_1
      end

    :ets.insert(name, {:current_table, inactive_table, :available})

    active_table
  end

  @spec inactive_table(atom(), t()) :: :ets.tid()
  def inactive_table(name, tables) do
    {table_1, table_2} = tables

    case active_table(name) do
      ^table_1 -> table_2
      ^table_2 -> table_1
    end
  end

  defp reset_counter(table), do: :ets.insert(table, {@counter_key, 0})

  defp active_table(name), do: :ets.lookup_element(name, :current_table, 2)
end
