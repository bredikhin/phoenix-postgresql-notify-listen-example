defmodule Pgsub.Pgsub.Todo do
  use Ecto.Schema
  import Ecto.Changeset
  alias Pgsub.Pgsub.Todo


  schema "todos" do
    field :completed, :boolean, default: false
    field :task, :string

    timestamps()
  end

  @doc false
  def changeset(%Todo{} = todo, attrs) do
    todo
    |> cast(attrs, [:task, :completed])
    |> validate_required([:task, :completed])
  end
end

defimpl Poison.Encoder, for: Pgsub.Pgsub.Todo do
  def encode(%{__struct__: _} = struct, options) do
    map = struct
          |> Map.from_struct
          |> Map.drop([:__meta__, :__struct__])
    Poison.Encoder.Map.encode(map, options)
  end
end
