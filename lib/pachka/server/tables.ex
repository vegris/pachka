defmodule Pachka.Server.Tables do
  @type t :: {:ets.tid(), :ets.tid()}

  @spec create(atom()) :: t()
  def create(name) do
    tables =
      1..2
      |> Enum.map(fn i ->
        :"#{name}.ExportTable#{i}"
        |> :ets.new([:set, :public, write_concurrency: true])
        |> tap(&:ets.insert(&1, {:counter, 0}))
      end)
      |> List.to_tuple()

    _ = :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(name, {:current_table, elem(tables, 0), :available})

    tables
  end

  @spec active_size(atom()) :: integer()
  def active_size(name) do
    name
    |> active_table()
    |> :ets.info(:size)
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

  defp active_table(name), do: :ets.lookup_element(name, :current_table, 2)
end
