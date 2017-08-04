defmodule Pgsub.Notifications do
  use GenServer
  alias Pgsub.{Pgsub.Todo, Repo}
  import Poison, only: [decode!: 1]
  def start_link(channel) do
    GenServer.start_link(__MODULE__, channel)
  end
  def init(channel) do
    {:ok, pid} = Application.get_env(:pgsub, Pgsub.Repo)
      |> Postgrex.Notifications.start_link()
    ref = Postgrex.Notifications.listen!(pid, channel)
    data = Todo |> Repo.all
    {:ok, {pid, ref, channel, data}}
  end
  @topic "todo:list"
  def handle_info({:notification, pid, ref, "todos_changes", payload}, {pid, ref, channel, data}) do
    %{
      "data" => raw,
      "id" => id,
      "table" => "todos",
      "type" => type
    } = decode!(payload)
    row = for {k, v} <- raw, into: %{}, do: {String.to_atom(k), v}
    updated_data = case type do
      "UPDATE" -> Enum.map(data, fn x -> if x.id === id do Map.merge(x, row) else x end end)
      "INSERT" -> data ++ [struct(Todo, row)]
      "DELETE" -> Enum.filter(data,  &(&1.id !== id))
    end
    PgsubWeb.Endpoint.broadcast!(@topic, "todos", %{todos: updated_data})
    {:noreply, {pid, ref, channel, updated_data}}
  end
end
