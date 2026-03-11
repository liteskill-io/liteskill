defmodule Liteskill.Acp.AgentConfig do
  @moduledoc """
  Schema for ACP (Agent Client Protocol) agent configurations.

  Stores the command, arguments, and environment needed to spawn
  an external AI agent that communicates via ACP over stdio.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "acp_agent_configs" do
    field :name, :string
    field :command, :string
    field :args, {:array, :string}, default: []
    field :env, :map, default: %{}
    field :description, :string
    field :status, :string, default: "active"
    field :instance_wide, :boolean, default: false

    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :command, :user_id]
  @optional_fields [:args, :env, :description, :status, :instance_wide]

  def changeset(config, attrs) do
    config
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["active", "inactive"])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:command, min: 1, max: 500)
    |> unique_constraint([:name, :user_id])
    |> foreign_key_constraint(:user_id)
  end
end
