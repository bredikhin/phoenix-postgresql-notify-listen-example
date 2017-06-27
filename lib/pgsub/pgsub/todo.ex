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
