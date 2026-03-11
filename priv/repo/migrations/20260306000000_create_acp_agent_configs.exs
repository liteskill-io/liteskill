defmodule Liteskill.Repo.Migrations.CreateAcpAgentConfigs do
  use Ecto.Migration

  def change do
    create table(:acp_agent_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :command, :string, null: false
      add :args, {:array, :string}, default: []
      add :env, :map, default: %{}
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :instance_wide, :boolean, null: false, default: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:acp_agent_configs, [:name, :user_id])
    create index(:acp_agent_configs, [:user_id])
    create index(:acp_agent_configs, [:status])
  end
end
