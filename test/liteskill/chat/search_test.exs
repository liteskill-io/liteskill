defmodule Liteskill.Chat.SearchTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat
  alias Liteskill.Chat.Search

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "search-test-#{System.unique_integer([:positive])}@example.com",
        name: "Search Tester",
        oidc_sub: "search-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other_user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "search-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "search-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    # Create conversations with messages
    {:ok, conv1} = Chat.create_conversation(%{user_id: user.id, title: "Conv About Elixir"})
    {:ok, _msg1} = Chat.send_message(conv1.id, user.id, "I love Elixir pattern matching")
    Process.sleep(50)

    {:ok, conv2} = Chat.create_conversation(%{user_id: user.id, title: "Conv About Phoenix"})
    {:ok, _msg2} = Chat.send_message(conv2.id, user.id, "Phoenix LiveView is amazing")
    Process.sleep(50)

    {:ok, other_conv} = Chat.create_conversation(%{user_id: other_user.id, title: "Private Conv"})
    {:ok, _} = Chat.send_message(other_conv.id, other_user.id, "This is private Elixir stuff")
    Process.sleep(50)

    %{user: user, other_user: other_user, conv1: conv1, conv2: conv2, other_conv: other_conv}
  end

  describe "search/3" do
    test "finds messages matching query", %{user: user} do
      results = Search.search(user.id, "Elixir")
      assert results != []

      assert Enum.any?(results, fn r ->
               String.contains?(r.snippet || "", "Elixir") or
                 String.contains?(to_string(r.conversation_title), "Elixir")
             end)
    end

    test "returns empty for empty query", %{user: user} do
      assert Search.search(user.id, "") == []
      assert Search.search(user.id, "   ") == []
    end

    test "does not return other user's messages", %{user: user} do
      results = Search.search(user.id, "private")
      assert results == []
    end

    test "respects limit", %{user: user} do
      results = Search.search(user.id, "Elixir", limit: 1)
      assert length(results) <= 1
    end

    test "returns results with expected fields", %{user: user} do
      results = Search.search(user.id, "pattern matching")

      if results != [] do
        result = hd(results)
        assert Map.has_key?(result, :message_id)
        assert Map.has_key?(result, :conversation_id)
        assert Map.has_key?(result, :conversation_title)
        assert Map.has_key?(result, :snippet)
        assert Map.has_key?(result, :role)
      end
    end
  end

  describe "Chat.search_messages/3 delegate" do
    test "delegates to Search.search", %{user: user} do
      results = Chat.search_messages(user.id, "Elixir")
      assert is_list(results)
    end
  end

  describe "fts_available?/0" do
    test "returns boolean" do
      assert is_boolean(Search.fts_available?())
    end
  end
end
