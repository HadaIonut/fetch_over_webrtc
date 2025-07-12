defmodule ClientSupervisor do
  use DynamicSupervisor

  def start_link(_) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_client(id) do
    spec = Supervisor.child_spec({ClientHandler, id}, restart: :temporary)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
