defmodule LiteskillWeb.Plugs.DesktopShortcuts do
  @moduledoc """
  LiveView on_mount hook for keyboard shortcuts and command palette.

  Attaches shared event handlers so all LiveViews in the :chat and :admin
  live_sessions respond to Cmd+K (command palette), Cmd+N (new conversation),
  Cmd+, (settings), Cmd+B (toggle sidebar), and Cmd+W (close/home).
  """

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:show_command_palette, false)
     |> attach_hook(:desktop_shortcuts, :handle_event, &handle_shortcut_event/3)}
  end

  defp handle_shortcut_event("toggle_command_palette", _params, socket) do
    {:halt, assign(socket, :show_command_palette, !socket.assigns.show_command_palette)}
  end

  defp handle_shortcut_event("close_command_palette", _params, socket) do
    {:halt, assign(socket, :show_command_palette, false)}
  end

  defp handle_shortcut_event("command_palette_navigate", %{"path" => path}, socket) do
    {:halt,
     socket
     |> assign(:show_command_palette, false)
     |> push_navigate(to: path)}
  end

  defp handle_shortcut_event("shortcut_new_conversation", _params, socket) do
    {:halt, push_navigate(socket, to: "/")}
  end

  defp handle_shortcut_event("shortcut_settings", _params, socket) do
    path =
      if Map.get(socket.assigns, :single_user_mode, false),
        do: "/settings",
        else: "/admin"

    {:halt, push_navigate(socket, to: path)}
  end

  defp handle_shortcut_event("shortcut_close", _params, socket) do
    {:halt, push_navigate(socket, to: "/")}
  end

  defp handle_shortcut_event(_event, _params, socket), do: {:cont, socket}
end
