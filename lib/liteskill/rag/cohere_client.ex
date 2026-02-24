defmodule Liteskill.Rag.CohereClient do
  @moduledoc """
  Req-based HTTP client for Cohere models on AWS Bedrock.

  Supports embed-v4 and rerank-v3.5.
  """

  alias Liteskill.Rag.RequestLogger

  require Logger

  @embed_model "us.cohere.embed-v4:0"
  @rerank_model "cohere.rerank-v3-5:0"

  @doc """
  Embed a list of texts using Cohere embed-v4.

  Required opts:
    - `input_type` - "search_document" or "search_query"

  Optional opts:
    - `dimensions` - output dimension (default 1024)
    - `truncate` - truncation strategy (default "RIGHT")
    - `plug` - Req test plug
    - `user_id` - user ID for embedding request tracking
  """
  def embed(texts, opts \\ []) do
    {user_id, opts} = Keyword.pop(opts, :user_id)
    {model_override, opts} = Keyword.pop(opts, :model_id)
    {req_opts, body_opts} = Keyword.split(opts, [:plug])

    model_id = model_override || resolve_embed_model()

    body = %{
      "texts" => texts,
      "input_type" => Keyword.fetch!(body_opts, :input_type),
      "embedding_types" => ["float"],
      "output_dimension" => Keyword.get(body_opts, :dimensions, 1024),
      "truncate" => Keyword.get(body_opts, :truncate, "RIGHT")
    }

    start = System.monotonic_time(:millisecond)

    result =
      case Req.post(base_req(), [{:url, invoke_url(model_id)}, {:json, body}] ++ req_opts) do
        {:ok, %{status: 200, body: %{"embeddings" => %{"float" => embeddings}}}} ->
          {:ok, embeddings}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        # coveralls-ignore-next-line
        {:error, reason} ->
          {:error, reason}
      end

    latency = System.monotonic_time(:millisecond) - start

    RequestLogger.log_request(user_id, %{
      request_type: "embed",
      model_id: model_id,
      input_count: length(texts),
      token_count: RequestLogger.estimate_token_count(texts),
      latency_ms: latency,
      result: result
    })

    result
  end

  @doc """
  Rerank documents against a query using Cohere rerank-v3.5.

  Optional opts:
    - `top_n` - number of top results (default 5)
    - `max_tokens_per_doc` - max tokens per document (default 4096)
    - `plug` - Req test plug
    - `user_id` - user ID for embedding request tracking
  """
  def rerank(query, documents, opts \\ []) do
    {user_id, opts} = Keyword.pop(opts, :user_id)
    {req_opts, body_opts} = Keyword.split(opts, [:plug])

    body = %{
      "query" => query,
      "documents" => documents,
      "top_n" => Keyword.get(body_opts, :top_n, 5),
      "max_tokens_per_doc" => Keyword.get(body_opts, :max_tokens_per_doc, 4096),
      "api_version" => 2
    }

    start = System.monotonic_time(:millisecond)

    result =
      case Req.post(base_req(), [{:url, invoke_url(@rerank_model)}, {:json, body}] ++ req_opts) do
        {:ok, %{status: 200, body: %{"results" => results}}} ->
          {:ok, results}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        # coveralls-ignore-next-line
        {:error, reason} ->
          {:error, reason}
      end

    latency = System.monotonic_time(:millisecond) - start

    RequestLogger.log_request(user_id, %{
      request_type: "rerank",
      model_id: @rerank_model,
      input_count: length(documents),
      token_count: RequestLogger.estimate_token_count([query | documents]),
      latency_ms: latency,
      result: result
    })

    result
  end

  defp resolve_embed_model do
    case Liteskill.Settings.get() do
      %{embedding_model: %{model_id: mid}} when is_binary(mid) -> mid
      _ -> @embed_model
    end
  end

  defp base_req do
    %{token: token} = resolve_credentials()

    Req.new(
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ],
      retry: false
    )
  end

  defp invoke_url(model_id) do
    %{region: region} = resolve_credentials()
    "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode(model_id)}/invoke"
  end

  defp resolve_credentials do
    db_creds =
      try do
        Liteskill.LlmProviders.get_bedrock_credentials()
      rescue
        # coveralls-ignore-start
        e ->
          Logger.warning("Failed to resolve DB credentials: #{Exception.message(e)}")
          nil
          # coveralls-ignore-stop
      end

    case db_creds do
      %{api_key: token, region: region} ->
        %{token: token, region: region}

      nil ->
        config = Application.get_env(:liteskill, Liteskill.LLM, [])

        %{
          token: Keyword.get(config, :bedrock_bearer_token),
          region: Keyword.get(config, :bedrock_region, "us-east-1")
        }
    end
  end
end
