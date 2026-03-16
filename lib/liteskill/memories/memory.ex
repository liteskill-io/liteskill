defmodule Liteskill.Memories.Memory do
  @moduledoc """
  Schema for user-scoped knowledge items extracted from conversations.

  Memories capture decisions, facts, insights, and preferences that
  persist across conversations, building a personal knowledge base.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ~w(decision fact insight preference)
  @statuses ~w(active archived)

  schema "memories" do
    field :category, :string, default: "insight"
    field :title, :string
    field :content, :string
    field :source_message_id, :binary_id
    field :metadata, :map, default: %{}
    field :status, :string, default: "active"

    belongs_to :user, Liteskill.Accounts.User
    belongs_to :conversation, Liteskill.Chat.Conversation

    timestamps(type: :utc_datetime)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:user_id, :conversation_id, :category, :title, :content, :source_message_id, :metadata, :status])
    |> validate_required([:user_id, :title, :content, :category])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, max: 500)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
  end

  def categories, do: @categories
end
