defmodule Pgsub.Web.TodoChannel do
  use Pgsub.Web, :channel
  alias Pgsub.{Pgsub.Todo, Repo}

  def join("todo:list", payload, socket) do
    if authorized?(payload) do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_in("todos", _payload, socket) do
    todos = Todo |> Repo.all
    Pgsub.Web.Endpoint.broadcast!(socket.topic, "todos", %{todos: todos})

    {:noreply, socket}
  end

  def handle_in("insert", %{"todo" => data}, socket) do
    %Todo{}
    |> Todo.changeset(data)
    |> Repo.insert!

    {:noreply, socket}
  end

  def handle_in("update", %{"todo" => data}, socket) do
    Todo
    |> Repo.get(data["id"])
    |> Todo.changeset(data)
    |> Repo.update!

    {:noreply, socket}
  end

  def handle_in("delete", %{"todo" => data}, socket) do
    Todo
    |> Repo.get(data["id"])
    |> Repo.delete!

    {:noreply, socket}
  end

  defp authorized?(_payload) do
    true
  end
end
