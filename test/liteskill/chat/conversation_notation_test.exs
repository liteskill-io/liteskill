defmodule Liteskill.Chat.ConversationNotationTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Aggregate.Loader
  alias Liteskill.Chat
  alias Liteskill.Chat.ConversationAggregate
  alias Liteskill.Chat.ConversationNotation
  alias Liteskill.Chat.Projector

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "notation-test-#{System.unique_integer([:positive])}@example.com",
        name: "Notation Tester",
        oidc_sub: "notation-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "export/2" do
    test "exports a simple conversation", %{user: user} do
      {:ok, conv} =
        Chat.create_conversation(%{
          user_id: user.id,
          title: "Export Test",
          model_id: "test-model",
          system_prompt: "Be helpful"
        })

      {:ok, _} = Chat.send_message(conv.id, user.id, "Hello")
      complete_assistant_reply(conv.stream_id, "Hi there!", "end_turn")

      assert {:ok, notation} = ConversationNotation.export(conv.id, user.id)
      assert notation["liteskill_version"] == "1.0"
      assert notation["exported_at"]
      assert notation["conversation"]["title"] == "Export Test"
      assert notation["conversation"]["model_id"] == "test-model"
      assert notation["conversation"]["system_prompt"] == "Be helpful"

      messages = notation["messages"]
      assert length(messages) >= 2

      user_msg = Enum.find(messages, &(&1["role"] == "user"))
      assert user_msg
      assert Enum.any?(user_msg["content"], &match?(%{"text" => "Hello"}, &1))

      assistant_msg = Enum.find(messages, &(&1["role"] == "assistant"))
      assert assistant_msg
      assert Enum.any?(assistant_msg["content"], &match?(%{"text" => "Hi there!"}, &1))
      assert assistant_msg["model_id"] == "test-model"
    end

    test "exports a conversation with tool calls", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Tool Export Test"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Search for something")

      message_id = Ecto.UUID.generate()
      tool_use_id = Ecto.UUID.generate()

      # Start assistant stream with tool use
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
        )

      Projector.project_events(conv.stream_id, events)

      # Start tool call
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:start_tool_call,
           %{
             message_id: message_id,
             tool_use_id: tool_use_id,
             tool_name: "search",
             input: %{"query" => "test"}
           }}
        )

      Projector.project_events(conv.stream_id, events)

      # Complete tool call
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:complete_tool_call,
           %{
             message_id: message_id,
             tool_use_id: tool_use_id,
             tool_name: "search",
             input: %{"query" => "test"},
             output: %{"content" => [%{"text" => "Found 5 results"}]},
             duration_ms: 100
           }}
        )

      Projector.project_events(conv.stream_id, events)

      # Complete assistant stream
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:complete_stream,
           %{
             message_id: message_id,
             full_content: "I found results",
             stop_reason: "tool_use",
             input_tokens: 10,
             output_tokens: 20,
             latency_ms: 500
           }}
        )

      Projector.project_events(conv.stream_id, events)
      Process.sleep(50)

      assert {:ok, notation} = ConversationNotation.export(conv.id, user.id)

      messages = notation["messages"]

      # Should have assistant message with toolUse blocks
      assistant_msg =
        Enum.find(messages, fn m ->
          m["role"] == "assistant" && Enum.any?(m["content"], &match?(%{"toolUse" => _}, &1))
        end)

      assert assistant_msg
      assert assistant_msg["model_id"] == "test-model"

      tool_use = Enum.find(assistant_msg["content"], &match?(%{"toolUse" => _}, &1))
      assert tool_use["toolUse"]["name"] == "search"
      assert tool_use["toolUse"]["input"] == %{"query" => "test"}

      # Should have user message with toolResult
      tool_result_msg =
        Enum.find(messages, fn m ->
          m["role"] == "user" && Enum.any?(m["content"], &match?(%{"toolResult" => _}, &1))
        end)

      assert tool_result_msg
    end

    test "returns error for non-existent conversation", %{user: user} do
      assert {:error, :not_found} = ConversationNotation.export(Ecto.UUID.generate(), user.id)
    end
  end

  describe "encode/1" do
    test "encodes notation as pretty JSON" do
      notation = %{"liteskill_version" => "1.0", "messages" => []}
      assert {:ok, json} = ConversationNotation.encode(notation)
      assert is_binary(json)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["liteskill_version"] == "1.0"
    end
  end

  describe "import_conversation/3" do
    test "imports a simple conversation from JSON", %{user: user} do
      json =
        Jason.encode!(%{
          "liteskill_version" => "1.0",
          "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "conversation" => %{
            "title" => "Imported Chat",
            "model_id" => "test-model",
            "system_prompt" => "Be helpful"
          },
          "messages" => [
            %{"role" => "user", "content" => [%{"text" => "Hello"}]},
            %{"role" => "assistant", "model_id" => "claude-3-sonnet", "content" => [%{"text" => "Hi there!"}]}
          ]
        })

      assert {:ok, conv} = ConversationNotation.import_conversation(json, user.id)
      assert conv.title == "Imported Chat"
      assert conv.model_id == "test-model"
      assert conv.system_prompt == "Be helpful"

      {:ok, conversation} = Chat.get_conversation(conv.id, user.id)
      messages = conversation.messages

      user_msg = Enum.find(messages, &(&1.role == "user"))
      assert user_msg
      assert user_msg.content == "Hello"

      assistant_msg = Enum.find(messages, &(&1.role == "assistant"))
      assert assistant_msg
      assert assistant_msg.content == "Hi there!"
      assert assistant_msg.model_id == "claude-3-sonnet"
    end

    test "imports conversation with tool calls", %{user: user} do
      tool_use_id = Ecto.UUID.generate()

      json =
        Jason.encode!(%{
          "liteskill_version" => "1.0",
          "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "conversation" => %{"title" => "Tool Import Test"},
          "messages" => [
            %{"role" => "user", "content" => [%{"text" => "Search for something"}]},
            %{
              "role" => "assistant",
              "model_id" => "claude-3-sonnet",
              "content" => [
                %{"text" => "Let me search"},
                %{"toolUse" => %{"toolUseId" => tool_use_id, "name" => "search", "input" => %{"query" => "test"}}}
              ]
            },
            %{
              "role" => "user",
              "content" => [
                %{
                  "toolResult" => %{
                    "toolUseId" => tool_use_id,
                    "content" => [%{"text" => "Found results"}],
                    "status" => "success"
                  }
                }
              ]
            },
            %{"role" => "assistant", "content" => [%{"text" => "I found some results for you."}]}
          ]
        })

      assert {:ok, conv} = ConversationNotation.import_conversation(json, user.id)

      {:ok, conversation} = Chat.get_conversation(conv.id, user.id)
      messages = conversation.messages

      # User message
      user_msgs = Enum.filter(messages, &(&1.role == "user"))
      assert [first_user | _] = user_msgs
      assert first_user.content == "Search for something"

      # Assistant messages
      assistant_msgs = Enum.filter(messages, &(&1.role == "assistant"))
      assert [_, _ | _] = assistant_msgs

      # One should have tool_use stop_reason with preserved model_id
      tool_assistant = Enum.find(assistant_msgs, &(&1.stop_reason == "tool_use"))
      assert tool_assistant
      assert tool_assistant.model_id == "claude-3-sonnet"
    end

    test "round-trip export then import preserves content", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Round Trip"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "First message")
      complete_assistant_reply(conv.stream_id, "First reply", "end_turn")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Second message")
      complete_assistant_reply(conv.stream_id, "Second reply", "end_turn")

      assert {:ok, notation} = ConversationNotation.export(conv.id, user.id)
      {:ok, json} = ConversationNotation.encode(notation)

      assert {:ok, imported_conv} = ConversationNotation.import_conversation(json, user.id)
      assert {:ok, re_exported} = ConversationNotation.export(imported_conv.id, user.id)

      # Messages should match
      assert length(re_exported["messages"]) == length(notation["messages"])

      notation["messages"]
      |> Enum.zip(re_exported["messages"])
      |> Enum.each(fn {original, imported} ->
        assert original["role"] == imported["role"]

        # Compare text content only (toolUseIds will differ)
        original_texts = extract_texts(original["content"])
        imported_texts = extract_texts(imported["content"])
        assert original_texts == imported_texts

        # model_id preserved on assistant messages
        if original["role"] == "assistant" do
          assert original["model_id"] == imported["model_id"]
        end
      end)
    end

    test "returns error for invalid JSON", %{user: user} do
      assert {:error, :invalid_json} = ConversationNotation.import_conversation("not json", user.id)
    end

    test "returns error for invalid notation structure", %{user: user} do
      json = Jason.encode!(%{"foo" => "bar"})
      assert {:error, :invalid_notation} = ConversationNotation.import_conversation(json, user.id)
    end

    test "returns error for unauthorized user" do
      json =
        Jason.encode!(%{
          "liteskill_version" => "1.0",
          "messages" => []
        })

      assert {:error, :forbidden} = ConversationNotation.import_conversation(json, nil)
    end

    test "imports conversation with empty messages", %{user: user} do
      json =
        Jason.encode!(%{
          "liteskill_version" => "1.0",
          "conversation" => %{"title" => "Empty Import"},
          "messages" => []
        })

      assert {:ok, conv} = ConversationNotation.import_conversation(json, user.id)
      assert conv.title == "Empty Import"
    end

    test "imports with default title when conversation metadata is missing", %{user: user} do
      json =
        Jason.encode!(%{
          "liteskill_version" => "1.0",
          "messages" => [
            %{"role" => "user", "content" => [%{"text" => "Hello"}]}
          ]
        })

      assert {:ok, conv} = ConversationNotation.import_conversation(json, user.id)
      assert conv.title == "Imported Conversation"
    end
  end

  # --- Helpers ---

  defp complete_assistant_reply(stream_id, content, stop_reason) do
    message_id = Ecto.UUID.generate()

    {:ok, _state, events} =
      Loader.execute(
        ConversationAggregate,
        stream_id,
        {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
      )

    Projector.project_events(stream_id, events)

    {:ok, _state, events} =
      Loader.execute(
        ConversationAggregate,
        stream_id,
        {:complete_stream,
         %{
           message_id: message_id,
           full_content: content,
           stop_reason: stop_reason,
           input_tokens: 10,
           output_tokens: 20,
           latency_ms: 100
         }}
      )

    Projector.project_events(stream_id, events)
    Process.sleep(50)
  end

  defp extract_texts(content_blocks) do
    Enum.flat_map(content_blocks || [], fn
      %{"text" => text} -> [text]
      _ -> []
    end)
  end
end
