defmodule Liteskill.Rag.Chunk do
  @moduledoc """
  Schema for RAG chunks. Embeddings stored as binary blobs; vector search is stubbed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_chunks" do
    field :content, :string
    field :position, :integer
    field :metadata, :map, default: %{}
    field :token_count, :integer
    field :content_hash, :string
    # Vector search is stubbed — embedding stored as binary blob for future use
    field :embedding, :binary

    belongs_to :document, Liteskill.Rag.Document

    timestamps(type: :utc_datetime)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :content,
      :position,
      :metadata,
      :token_count,
      :content_hash,
      :embedding,
      :document_id
    ])
    |> validate_required([:content, :position, :document_id])
    |> foreign_key_constraint(:document_id)
  end
end
