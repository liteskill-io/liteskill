defmodule LiteskillWeb.E2E.NotationTest do
  use LiteskillWeb.FeatureCase, async: false

  import Ecto.Query

  alias Liteskill.Chat.ConversationNotation
  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Repo

  test "export: JSON notation viewer shows conversation and download works", %{session: session} do
    mock_llm_stream("This is a test response for JSON export.")
    seed_provider_and_model()

    register_user(session)

    # Send a message to create a conversation
    session
    |> visit("/")
    |> assert_has(Query.css("#message-input"))
    |> fill_in(Query.css("#message-input"), with: "Hello for export test")
    |> click(Query.css("button[type='submit']"))

    # Wait for the assistant response
    assert_has(session, Query.css(".prose", text: "This is a test response for JSON export.", count: :any))
    Process.sleep(500)

    # Toggle JSON notation viewer
    session
    |> click(Query.css("button[title='JSON notation']"))
    |> assert_has(Query.css("#json-viewer-content"))
    |> take_screenshot(name: "notation/export/json_viewer_open")

    # Verify key JSON fields are visible
    session
    |> assert_has(Query.css("#json-viewer-content", text: "liteskill_version"))
    |> assert_has(Query.css("#json-viewer-content", text: "messages"))
    |> take_screenshot(name: "notation/export/json_content")

    # Click download button
    session
    |> click(Query.css("#download-json-btn"))
    |> take_screenshot(name: "notation/export/after_download_click")

    # Toggle back to chat view
    session
    |> click(Query.css("button[title='JSON notation']"))
    |> assert_has(Query.css(".prose", text: "This is a test response for JSON export.", count: :any))
    |> take_screenshot(name: "notation/export/back_to_chat")
  end

  test "import: uploading a JSON file creates a new conversation", %{session: session} do
    register_user(session)

    # Create a valid notation JSON file
    notation = %{
      "liteskill_version" => "1.0",
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "conversation" => %{
        "title" => "Imported E2E Test",
        "model_id" => "test-model",
        "system_prompt" => nil
      },
      "messages" => [
        %{
          "role" => "user",
          "content" => [%{"text" => "What is Elixir?"}]
        },
        %{
          "role" => "assistant",
          "content" => [%{"text" => "Elixir is a dynamic, functional language for building scalable applications."}]
        }
      ]
    }

    json_content = Jason.encode!(notation, pretty: true)
    tmp_path = Path.join(System.tmp_dir!(), "e2e_import_test_#{System.unique_integer([:positive])}.json")
    File.write!(tmp_path, json_content)
    on_exit(fn -> File.rm(tmp_path) end)

    # Navigate to new chat page where import section is visible
    session
    |> visit("/")
    |> assert_has(Query.css("#import-form"))
    |> take_screenshot(name: "notation/import/import_form_visible")

    # Attach the JSON file
    attach_file(session, Query.css("#import-form input[type='file']", visible: false), path: tmp_path)

    # Wait for the file entry to appear and click Import
    session
    |> assert_has(Query.button("Import"))
    |> take_screenshot(name: "notation/import/file_attached")
    |> click(Query.button("Import"))

    # Should redirect to the imported conversation
    session
    |> assert_has(Query.css("h1", text: "Imported E2E Test"))
    |> take_screenshot(name: "notation/import/imported_conversation")

    # Verify the messages are visible
    session
    |> assert_has(Query.css(".bg-primary", text: "What is Elixir?", count: :any))
    |> assert_has(Query.css(".prose", text: "Elixir is a dynamic, functional language", count: :any))
    |> take_screenshot(name: "notation/import/imported_messages")
  end

  test "round-trip: export then import preserves conversation", %{session: session} do
    mock_llm_stream("Round-trip test response content.")
    seed_provider_and_model()

    %{email: email} = register_user(session)

    # Create a conversation with a message
    session
    |> visit("/")
    |> assert_has(Query.css("#message-input"))
    |> fill_in(Query.css("#message-input"), with: "Round-trip export test")
    |> click(Query.css("button[type='submit']"))

    assert_has(session, Query.css(".prose", text: "Round-trip test response content.", count: :any))
    Process.sleep(500)

    # Open JSON viewer and verify export content
    session
    |> click(Query.css("button[title='JSON notation']"))
    |> assert_has(Query.css("#json-viewer-content"))
    |> assert_has(Query.css("#json-viewer-content", text: "Round-trip export test"))
    |> assert_has(Query.css("#json-viewer-content", text: "Round-trip test response content."))
    |> take_screenshot(name: "notation/roundtrip/exported_json")

    # Export server-side using the conversation from the DB
    user = Repo.get_by!(Liteskill.Accounts.User, email: email)

    conv =
      Repo.one!(
        from(c in Liteskill.Chat.Conversation,
          where: c.user_id == ^user.id,
          order_by: [desc: c.inserted_at],
          limit: 1
        )
      )

    {:ok, notation} = ConversationNotation.export(conv.id, user.id)
    {:ok, json} = ConversationNotation.encode(notation)

    # Write to temp file for import
    tmp_path = Path.join(System.tmp_dir!(), "e2e_roundtrip_#{System.unique_integer([:positive])}.json")
    File.write!(tmp_path, json)
    on_exit(fn -> File.rm(tmp_path) end)

    # Navigate to new chat and import
    session
    |> visit("/")
    |> assert_has(Query.css("#import-form"))
    |> attach_file(Query.css("#import-form input[type='file']", visible: false), path: tmp_path)
    |> assert_has(Query.button("Import"))
    |> click(Query.button("Import"))

    # Verify the imported conversation has the same content
    session
    |> assert_has(Query.css(".bg-primary", text: "Round-trip export test", count: :any))
    |> assert_has(Query.css(".prose", text: "Round-trip test response content.", count: :any))
    |> take_screenshot(name: "notation/roundtrip/imported_conversation")
  end

  defp seed_provider_and_model do
    %{id: user_id} = create_user(%{email: "seed-notation@example.com"}).user

    provider =
      Repo.insert!(%LlmProvider{
        name: "Notation Test Provider",
        provider_type: "anthropic",
        api_key: "sk-fake",
        instance_wide: true,
        status: "active",
        user_id: user_id
      })

    Repo.insert!(%LlmModel{
      name: "Notation Test Model",
      model_id: "claude-test",
      model_type: "inference",
      instance_wide: true,
      status: "active",
      provider_id: provider.id,
      user_id: user_id
    })
  end
end
