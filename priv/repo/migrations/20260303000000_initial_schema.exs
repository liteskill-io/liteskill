defmodule Liteskill.Repo.Migrations.InitialSchema do
  @moduledoc false

  use Ecto.Migration

  def up do
    # -------------------------------------------------------------------------
    # Event Store
    # -------------------------------------------------------------------------
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stream_id, :string, null: false
      add :stream_version, :integer, null: false
      add :event_type, :string, null: false
      add :data, :map, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:events, [:stream_id, :stream_version])
    create index(:events, [:stream_id])
    create index(:events, [:event_type])
    create index(:events, [:inserted_at])

    create table(:snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stream_id, :string, null: false
      add :stream_version, :integer, null: false
      add :snapshot_type, :string, null: false
      add :data, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:snapshots, [:stream_id, :stream_version])
    create index(:snapshots, [:stream_id])

    # -------------------------------------------------------------------------
    # Users
    # -------------------------------------------------------------------------
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :oidc_sub, :string
      add :oidc_issuer, :string
      add :oidc_claims, :map, default: %{}
      add :password_hash, :string
      add :role, :string, null: false, default: "user"
      add :preferences, :map, default: %{}
      add :force_password_change, :boolean, null: false, default: false
      add :saml_name_id, :string
      add :saml_issuer, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:oidc_sub, :oidc_issuer],
             where: "oidc_sub IS NOT NULL AND oidc_issuer IS NOT NULL",
             name: :users_oidc_sub_oidc_issuer_index
           )

    create unique_index(:users, [:email])

    create unique_index(:users, [:saml_name_id, :saml_issuer],
             where: "saml_name_id IS NOT NULL AND saml_issuer IS NOT NULL",
             name: :users_saml_name_id_saml_issuer_index
           )

    # -------------------------------------------------------------------------
    # Groups
    # -------------------------------------------------------------------------
    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :created_by, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:groups, [:created_by])

    create table(:group_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_memberships, [:group_id, :user_id])
    create index(:group_memberships, [:user_id])
    create index(:group_memberships, [:group_id])

    # -------------------------------------------------------------------------
    # Roles (RBAC)
    # -------------------------------------------------------------------------
    create table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :system, :boolean, null: false, default: false
      # stored as JSON array string; Ecto {:array, :string} type handles serialization
      add :permissions, :string, null: false, default: "[]"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:name])

    # -------------------------------------------------------------------------
    # MCP Servers
    # -------------------------------------------------------------------------
    create table(:mcp_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :url, :string, null: false
      # encrypted text (Liteskill.Crypto.encrypt/1)
      add :api_key, :string
      add :description, :string
      # encrypted JSON text (was :map, encrypted in migration)
      add :headers, :string
      add :status, :string, null: false, default: "active"
      add :global, :boolean, null: false, default: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:mcp_servers, [:user_id])

    # -------------------------------------------------------------------------
    # LLM Providers & Models
    # -------------------------------------------------------------------------
    create table(:llm_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :provider_type, :string, null: false
      add :api_key, :text
      add :provider_config, :text
      add :instance_wide, :boolean, null: false, default: false
      add :status, :string, null: false, default: "active"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:llm_providers, [:user_id])
    create unique_index(:llm_providers, [:name, :user_id])

    create table(:llm_models, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :model_id, :string, null: false

      add :provider_id,
          references(:llm_providers, type: :binary_id, on_delete: :restrict),
          null: false

      add :model_type, :string, null: false, default: "inference"
      add :model_config, :text
      add :instance_wide, :boolean, null: false, default: false
      add :status, :string, null: false, default: "active"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :input_cost_per_million, :decimal
      add :output_cost_per_million, :decimal
      add :context_window, :integer
      add :max_output_tokens, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:llm_models, [:user_id])
    create index(:llm_models, [:provider_id])
    create unique_index(:llm_models, [:provider_id, :model_id])

    # -------------------------------------------------------------------------
    # Agent Definitions
    # -------------------------------------------------------------------------
    create table(:agent_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :backstory, :text
      add :opinions, :map, default: %{}
      add :system_prompt, :text
      add :strategy, :string, null: false, default: "react"
      add :config, :map, default: %{}
      add :status, :string, null: false, default: "active"
      add :llm_model_id, references(:llm_models, type: :binary_id, on_delete: :nilify_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:agent_definitions, [:user_id])
    create unique_index(:agent_definitions, [:name, :user_id])

    # -------------------------------------------------------------------------
    # Team Definitions & Members
    # -------------------------------------------------------------------------
    create table(:team_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :shared_context, :text
      add :default_topology, :string, null: false, default: "pipeline"
      add :aggregation_strategy, :string, null: false, default: "last"
      add :config, :map, default: %{}
      add :status, :string, null: false, default: "active"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:team_definitions, [:user_id])
    create unique_index(:team_definitions, [:name, :user_id])

    create table(:team_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "worker"
      add :description, :text
      add :position, :integer, null: false, default: 0

      add :team_definition_id,
          references(:team_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:team_members, [:team_definition_id])
    create index(:team_members, [:agent_definition_id])

    create unique_index(:team_members, [:team_definition_id, :agent_definition_id],
             name: :team_members_unique_idx
           )

    # -------------------------------------------------------------------------
    # Runs (formerly Instances) & Run Tasks & Run Logs
    # -------------------------------------------------------------------------
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :prompt, :text, null: false
      add :topology, :string, null: false, default: "pipeline"
      add :status, :string, null: false, default: "pending"
      add :context, :map, default: %{}
      add :deliverables, :map, default: %{}
      add :error, :text
      add :timeout_ms, :integer, default: 1_800_000
      add :max_iterations, :integer, default: 50
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :cost_limit, :decimal

      add :team_definition_id,
          references(:team_definitions, type: :binary_id, on_delete: :nilify_all)

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:user_id])
    create index(:runs, [:team_definition_id])
    create index(:runs, [:status])

    create table(:run_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "pending"
      add :position, :integer, null: false, default: 0
      add :input_summary, :text
      add :output_summary, :text
      add :error, :text
      add :duration_ms, :integer
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:run_tasks, [:run_id])
    create index(:run_tasks, [:agent_definition_id])

    create table(:run_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :level, :string, null: false
      add :step, :string, null: false
      add :message, :text, null: false
      add :metadata, :map, default: %{}
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:run_logs, [:run_id])

    # -------------------------------------------------------------------------
    # Schedules
    # -------------------------------------------------------------------------
    create table(:schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :cron_expression, :string, null: false
      add :timezone, :string, null: false, default: "UTC"
      add :enabled, :boolean, null: false, default: true
      add :status, :string, null: false, default: "active"
      add :prompt, :text, null: false
      add :topology, :string, null: false, default: "pipeline"
      add :context, :map, default: %{}
      add :timeout_ms, :integer, default: 1_800_000
      add :max_iterations, :integer, default: 50
      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime

      add :team_definition_id,
          references(:team_definitions, type: :binary_id, on_delete: :nilify_all)

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:schedules, [:user_id])
    create index(:schedules, [:team_definition_id])
    create index(:schedules, [:enabled, :next_run_at])
    create unique_index(:schedules, [:name, :user_id])

    # -------------------------------------------------------------------------
    # Conversations & Messages
    # -------------------------------------------------------------------------
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stream_id, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string
      add :model_id, :string
      add :system_prompt, :text
      add :status, :string, null: false, default: "active"

      add :parent_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :fork_at_version, :integer
      add :message_count, :integer, null: false, default: 0
      add :last_message_at, :utc_datetime
      add :llm_model_id, references(:llm_models, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversations, [:stream_id])
    create index(:conversations, [:user_id])
    create index(:conversations, [:parent_conversation_id])
    create index(:conversations, [:llm_model_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :string, null: false
      add :content, :text
      add :status, :string, null: false, default: "complete"
      add :model_id, :string
      add :stop_reason, :string
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :total_tokens, :integer
      add :latency_ms, :integer
      add :stream_version, :integer
      add :position, :integer, null: false
      add :rag_sources, :map
      add :tool_config, :map

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:conversation_id])
    create index(:messages, [:conversation_id, :position])

    create table(:message_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id,
          references(:messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :chunk_index, :integer, null: false
      add :content_block_index, :integer, null: false, default: 0
      add :delta_type, :string, null: false, default: "text_delta"
      add :delta_text, :text
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:message_chunks, [:message_id])
    create index(:message_chunks, [:message_id, :chunk_index])

    create table(:tool_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id,
          references(:messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :tool_use_id, :string, null: false
      add :tool_name, :string, null: false
      add :input, :map
      add :output, :map
      add :status, :string, null: false, default: "started"
      add :duration_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:tool_calls, [:message_id])
    create unique_index(:tool_calls, [:tool_use_id])

    # -------------------------------------------------------------------------
    # Reports & Sections & Comments
    # -------------------------------------------------------------------------
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:reports, [:user_id])
    create index(:reports, [:run_id])

    create table(:report_sections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :report_id, references(:reports, type: :binary_id, on_delete: :delete_all), null: false

      add :parent_section_id,
          references(:report_sections, type: :binary_id, on_delete: :delete_all)

      add :title, :string, null: false
      add :content, :text
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:report_sections, [:report_id])
    create index(:report_sections, [:parent_section_id])

    create table(:section_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :body, :text, null: false
      add :author_type, :string, null: false
      add :status, :string, null: false, default: "open"
      add :section_id, references(:report_sections, type: :binary_id, on_delete: :delete_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :report_id, references(:reports, type: :binary_id, on_delete: :delete_all), null: false

      add :parent_comment_id,
          references(:section_comments, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:section_comments, [:section_id])
    create index(:section_comments, [:user_id])
    create index(:section_comments, [:report_id])
    create index(:section_comments, [:parent_comment_id])

    # -------------------------------------------------------------------------
    # Entity ACLs (unified — replaces conversation_acls, report_acls, agent_tools)
    # -------------------------------------------------------------------------
    create table(:entity_acls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :entity_type, :string, null: false
      add :entity_id, :binary_id, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all)

      add :role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime)
    end

    create index(:entity_acls, [:entity_type, :entity_id])
    create index(:entity_acls, [:user_id])
    create index(:entity_acls, [:group_id])
    create index(:entity_acls, [:agent_definition_id])

    create unique_index(:entity_acls, [:entity_type, :entity_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :entity_acls_entity_user_idx
           )

    create unique_index(:entity_acls, [:entity_type, :entity_id, :group_id],
             where: "group_id IS NOT NULL",
             name: :entity_acls_entity_group_idx
           )

    create unique_index(:entity_acls, [:entity_type, :entity_id, :agent_definition_id],
             where: "agent_definition_id IS NOT NULL",
             name: :entity_acls_entity_agent_idx
           )

    # SQLite does not support ALTER TABLE ADD CONSTRAINT — exactly-one-grantee
    # is enforced at the changeset level instead.

    # -------------------------------------------------------------------------
    # RBAC — User & Group Roles, Agent Roles
    # -------------------------------------------------------------------------
    create table(:user_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_roles, [:user_id, :role_id])
    create index(:user_roles, [:role_id])

    create table(:group_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_roles, [:group_id, :role_id])
    create index(:group_roles, [:role_id])

    create table(:agent_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_roles, [:agent_definition_id, :role_id])
    create index(:agent_roles, [:role_id])

    # -------------------------------------------------------------------------
    # LLM Usage Records
    # -------------------------------------------------------------------------
    create table(:llm_usage_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :nilify_all)
      add :message_id, :binary_id
      add :model_id, :string, null: false
      add :llm_model_id, references(:llm_models, type: :binary_id, on_delete: :nilify_all)
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :total_tokens, :integer, default: 0
      add :reasoning_tokens, :integer, default: 0
      add :cached_tokens, :integer, default: 0
      add :cache_creation_tokens, :integer, default: 0
      add :input_cost, :decimal
      add :output_cost, :decimal
      add :reasoning_cost, :decimal
      add :total_cost, :decimal
      add :latency_ms, :integer
      add :call_type, :string, null: false
      add :tool_round, :integer, default: 0
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:llm_usage_records, [:user_id, :inserted_at])
    create index(:llm_usage_records, [:conversation_id])
    create index(:llm_usage_records, [:user_id, :model_id])
    create index(:llm_usage_records, [:llm_model_id])
    create index(:llm_usage_records, [:run_id])
    create index(:llm_usage_records, [:inserted_at])

    # -------------------------------------------------------------------------
    # Server Settings (singleton row)
    # -------------------------------------------------------------------------
    create table(:server_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :registration_open, :boolean, null: false, default: true
      add :singleton, :boolean, null: false, default: true
      add :embedding_model_id, references(:llm_models, type: :binary_id, on_delete: :nilify_all)
      add :allow_private_mcp_urls, :boolean, null: false, default: false
      add :default_mcp_run_cost_limit, :decimal, default: 1.0
      add :setup_dismissed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:server_settings, [:singleton])
    create index(:server_settings, [:embedding_model_id])

    # -------------------------------------------------------------------------
    # Invitations
    # -------------------------------------------------------------------------
    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token])
    create index(:invitations, [:email])
    create index(:invitations, [:created_by_id])

    # -------------------------------------------------------------------------
    # Data Sources & Documents
    # -------------------------------------------------------------------------
    create table(:data_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :source_type, :string, null: false
      add :description, :string
      # encrypted JSON text (was :map, then encrypted)
      add :metadata, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :sync_cursor, :map, default: %{}
      add :sync_status, :string, default: "idle"
      add :last_synced_at, :utc_datetime
      add :last_sync_error, :text
      add :sync_document_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:data_sources, [:user_id])

    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :content, :text
      add :content_type, :string, null: false, default: "markdown"
      add :metadata, :map, default: %{}
      add :source_ref, :string, null: false
      add :slug, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_document_id, references(:documents, type: :binary_id, on_delete: :delete_all)
      add :position, :integer, null: false, default: 0
      add :external_id, :string
      add :content_hash, :string

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:source_ref])
    create index(:documents, [:user_id])
    create index(:documents, [:parent_document_id])

    create index(:documents, [:source_ref, :external_id],
             name: :documents_source_ref_external_id_index
           )

    create unique_index(:documents, [:source_ref, :parent_document_id, :slug],
             name: :documents_source_ref_parent_slug_index
           )

    create unique_index(:documents, [:source_ref, :slug],
             where: "parent_document_id IS NULL",
             name: :documents_source_ref_root_slug_index
           )

    # -------------------------------------------------------------------------
    # RAG — Collections, Sources, Documents, Chunks, Embedding Requests
    # -------------------------------------------------------------------------
    create table(:rag_collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :embedding_dimensions, :integer, null: false, default: 1024
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_collections, [:user_id])

    create table(:rag_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :source_type, :string, null: false, default: "manual"
      add :metadata, :map, default: %{}

      add :collection_id,
          references(:rag_collections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_sources, [:collection_id])
    create index(:rag_sources, [:user_id])

    create table(:rag_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :content, :text
      add :metadata, :map, default: %{}
      add :chunk_count, :integer, default: 0
      add :status, :string, null: false, default: "pending"

      add :source_id, references(:rag_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :content_hash, :string, size: 64
      add :error_message, :text

      timestamps(type: :utc_datetime)
    end

    create index(:rag_documents, [:source_id])
    create index(:rag_documents, [:user_id])
    create index(:rag_documents, [:content_hash])

    create table(:rag_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :content, :text, null: false
      add :position, :integer, null: false
      add :metadata, :map, default: %{}
      add :token_count, :integer

      add :document_id,
          references(:rag_documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :content_hash, :string, size: 64
      # Embedding stored as binary blob; vector search is stubbed (no HNSW in SQLite)
      add :embedding, :binary

      timestamps(type: :utc_datetime)
    end

    create index(:rag_chunks, [:document_id])
    create index(:rag_chunks, [:content_hash])

    create table(:rag_embedding_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :request_type, :string, null: false
      add :status, :string, null: false
      add :latency_ms, :integer
      add :input_count, :integer
      add :token_count, :integer
      add :model_id, :string
      add :error_message, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_embedding_requests, [:user_id])
    create index(:rag_embedding_requests, [:status])
    create index(:rag_embedding_requests, [:inserted_at])

    # -------------------------------------------------------------------------
    # User Tool Selections
    # -------------------------------------------------------------------------
    create table(:user_tool_selections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :server_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_tool_selections, [:user_id, :server_id])
    create index(:user_tool_selections, [:user_id])

    # -------------------------------------------------------------------------
    # User Sessions & Auth Events
    # -------------------------------------------------------------------------
    create table(:user_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :ip_address, :string
      add :user_agent, :string
      add :last_active_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_sessions, [:user_id])
    create index(:user_sessions, [:expires_at])
    create index(:user_sessions, [:last_active_at])

    create table(:auth_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :ip_address, :string
      add :user_agent, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:auth_events, [:user_id, :inserted_at])
    create index(:auth_events, [:event_type, :inserted_at])

    # -------------------------------------------------------------------------
    # Oban Jobs
    # -------------------------------------------------------------------------
    Oban.Migration.up(version: 12)
  end

  def down do
    Oban.Migration.down(version: 1)

    drop_if_exists table(:auth_events)
    drop_if_exists table(:user_sessions)
    drop_if_exists table(:user_tool_selections)
    drop_if_exists table(:rag_embedding_requests)
    drop_if_exists table(:rag_chunks)
    drop_if_exists table(:rag_documents)
    drop_if_exists table(:rag_sources)
    drop_if_exists table(:rag_collections)
    drop_if_exists table(:documents)
    drop_if_exists table(:data_sources)
    drop_if_exists table(:invitations)
    drop_if_exists table(:server_settings)
    drop_if_exists table(:llm_usage_records)
    drop_if_exists table(:agent_roles)
    drop_if_exists table(:group_roles)
    drop_if_exists table(:user_roles)
    drop_if_exists table(:entity_acls)
    drop_if_exists table(:section_comments)
    drop_if_exists table(:report_sections)
    drop_if_exists table(:reports)
    drop_if_exists table(:tool_calls)
    drop_if_exists table(:message_chunks)
    drop_if_exists table(:messages)
    drop_if_exists table(:conversations)
    drop_if_exists table(:run_logs)
    drop_if_exists table(:run_tasks)
    drop_if_exists table(:runs)
    drop_if_exists table(:schedules)
    drop_if_exists table(:team_members)
    drop_if_exists table(:team_definitions)
    drop_if_exists table(:agent_definitions)
    drop_if_exists table(:llm_models)
    drop_if_exists table(:llm_providers)
    drop_if_exists table(:mcp_servers)
    drop_if_exists table(:roles)
    drop_if_exists table(:group_memberships)
    drop_if_exists table(:groups)
    drop_if_exists table(:users)
    drop_if_exists table(:snapshots)
    drop_if_exists table(:events)
  end
end
