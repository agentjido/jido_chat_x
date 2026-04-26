defmodule Jido.Chat.X.Adapter do
  @moduledoc "X/Twitter Direct Messages `Jido.Chat.Adapter` implementation."
  use Jido.Chat.Adapter

  alias Jido.Chat.{
    Attachment,
    Author,
    EventEnvelope,
    FileUpload,
    ID,
    Incoming,
    Media,
    Message,
    MessagePage,
    PostPayload,
    Response,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.X.Transport.XdkClient

  @impl true
  def channel_type, do: :x

  @impl true
  def capabilities do
    %{
      send_message: :native,
      delete_message: :native,
      fetch_messages: :native,
      webhook: :native,
      verify_webhook: :native,
      parse_event: :native,
      format_webhook_response: :native,
      post_message: :native,
      send_file: :native,
      edit_message: :unsupported,
      start_typing: :unsupported,
      post_ephemeral: :unsupported,
      open_modal: :unsupported,
      fetch_message: :native,
      open_dm: :native,
      markdown: :fallback,
      multi_file: :native
    }
  end

  @impl true
  def transform_incoming(%{"dm_event" => event} = payload),
    do: {:ok, incoming_from_dm(event, payload)}

  def transform_incoming(%{"type" => "MessageCreate"} = event),
    do: {:ok, incoming_from_dm(event, event)}

  def transform_incoming(%{"type" => "message_create"} = event),
    do: {:ok, incoming_from_dm(event, event)}

  def transform_incoming(%{"event_type" => "MessageCreate"} = event),
    do: {:ok, incoming_from_dm(event, event)}

  def transform_incoming(%{"event_type" => "message_create"} = event),
    do: {:ok, incoming_from_dm(event, event)}

  def transform_incoming(_), do: {:error, :unsupported_payload}

  @impl true
  def send_message(room_id, text, opts \\ []) do
    with {:ok, raw} <- send_text(room_id, text, opts) do
      {:ok, response_from_send(raw, room_id)}
    end
  end

  @impl true
  def post_message(room_id, payload, opts \\ [])

  def post_message(room_id, %PostPayload{} = payload, opts) do
    with {:ok, text} <- render_post_text(payload, opts),
         {:ok, raw} <- send_text(room_id, text, opts) do
      {:ok,
       raw
       |> response_from_send(room_id)
       |> put_response_metadata(:attachments, PostPayload.outbound_attachments(payload))}
    end
  end

  def post_message(room_id, payload, opts) when is_map(payload) do
    post_message(room_id, PostPayload.new(payload), opts)
  end

  @impl true
  def send_file(room_id, file, opts \\ []) do
    upload = FileUpload.normalize(file)
    caption = Keyword.get(opts, :caption) || Keyword.get(opts, :text)

    payload =
      PostPayload.new(%{
        kind: :text,
        text: caption,
        files: [upload],
        metadata: Keyword.get(opts, :metadata, %{})
      })

    post_message(room_id, payload, Keyword.drop(opts, [:caption, :text]))
  end

  @impl true
  def delete_message(_room_id, event_id, opts \\ []) do
    transport(opts).delete_dm_event(to_string(event_id), opts)
  end

  @impl true
  def fetch_message(room_id, event_id, opts \\ []) do
    with {:ok, raw} <- transport(opts).fetch_dm_event(to_string(event_id), opts) do
      event = raw["data"] || raw[:data] || raw
      {:ok, message_from_event(event, room_id, raw)}
    end
  end

  @impl true
  def fetch_messages(room_id, opts \\ []) do
    conversation_id = String.replace_prefix(to_string(room_id), "conversation:", "")

    with {:ok, raw} <- transport(opts).fetch_conversation_messages(conversation_id, opts) do
      events = raw["data"] || raw[:data] || raw

      messages =
        events
        |> List.wrap()
        |> Enum.map(&message_from_event(&1, room_id, raw))

      {:ok, MessagePage.new(%{messages: messages, metadata: %{"raw" => raw}})}
    end
  end

  @impl true
  def open_dm(user_id, _opts \\ []), do: {:ok, to_string(user_id)}

  @impl true
  def handle_webhook(%Jido.Chat{} = chat, payload, opts \\ []) when is_map(payload) do
    request =
      WebhookRequest.new(%{
        adapter_name: :x,
        headers: opts[:headers] || %{},
        method: opts[:method] || "POST",
        query: opts[:query] || %{},
        payload: payload,
        raw: opts[:raw_body] || opts[:raw] || payload,
        metadata: %{raw_body: opts[:raw_body] || opts[:raw]}
      })

    with :ok <- verify_webhook(request, opts),
         {:ok, parsed_event} <- parse_event(request, opts) do
      route_parsed_event(chat, parsed_event, opts, request)
    end
  end

  @impl true
  def verify_webhook(request, opts \\ [])

  def verify_webhook(%WebhookRequest{method: method} = request, opts) do
    secret = consumer_secret(opts)

    cond do
      secret in [nil, ""] ->
        {:error, :missing_consumer_secret}

      get_request?(method) and crc_token(request) not in [nil, ""] ->
        :ok

      get_request?(method) ->
        {:error, :missing_crc_token}

      valid_signature?(request, secret) ->
        :ok

      true ->
        {:error, :invalid_signature}
    end
  end

  def verify_webhook(request, opts) when is_map(request) do
    request
    |> WebhookRequest.new()
    |> verify_webhook(opts)
  end

  @impl true
  def parse_event(request, opts \\ [])

  def parse_event(%WebhookRequest{method: method} = request, _opts) do
    case {get_request?(method), dm_events(request.payload)} do
      {true, _events} -> {:ok, :noop}
      {false, [event | _rest]} -> event_envelope(event, request)
      {false, []} -> {:ok, :noop}
    end
  end

  def parse_event(request, opts) when is_map(request) do
    request
    |> WebhookRequest.new()
    |> parse_event(opts)
  end

  @impl true
  def format_webhook_response(%WebhookRequest{method: method} = request, opts)
      when is_binary(method) do
    format_crc_response(request, consumer_secret(opts), get_request?(method))
  end

  def format_webhook_response({:ok, _chat, _incoming}, _opts), do: WebhookResponse.accepted()
  def format_webhook_response({:ok, :noop}, _opts), do: WebhookResponse.accepted()

  def format_webhook_response({:error, reason}, _opts),
    do: WebhookResponse.error(400, inspect(reason))

  def format_webhook_response(_, _opts), do: WebhookResponse.accepted()

  defp send_text(room_id, text, opts) do
    if conversation_room_id?(room_id) do
      transport(opts).send_conversation_message(conversation_id(room_id), to_string(text), opts)
    else
      transport(opts).send_dm(to_string(room_id), to_string(text), opts)
    end
  end

  defp render_post_text(%PostPayload{} = payload, opts) do
    base =
      payload.markdown || payload.formatted || PostPayload.display_text(payload) ||
        payload.fallback_text

    with {:ok, attachment_lines} <- attachment_lines(PostPayload.outbound_attachments(payload)) do
      [reply_context(opts), blank_to_nil(base) | attachment_lines]
      |> render_text_sections()
    end
  end

  defp attachment_lines(attachments) when is_list(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case attachment_line(Attachment.normalize(attachment)) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      {:error, _reason} = error -> error
    end
  end

  defp attachment_line(%Attachment{url: url} = attachment) when is_binary(url) and url != "" do
    label = attachment.filename || filename_from_url(url) || "attachment"
    {:ok, "#{label}: #{url}"}
  end

  defp attachment_line(%Attachment{}),
    do: {:error, {:unsupported_file_upload, :x_requires_media_upload_or_remote_url}}

  defp reply_context(opts) do
    case Keyword.get(opts, :reply_to_id) || Keyword.get(opts, :quote_id) do
      message_id when message_id in [nil, ""] -> nil
      message_id -> "Replying to #{message_id}:"
    end
  end

  defp render_text_sections(sections) do
    body =
      sections
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> String.trim()

    if body == "", do: {:error, :empty_message}, else: {:ok, body}
  end

  defp route_parsed_event(chat, :noop, _opts, %WebhookRequest{} = request) do
    {:ok, chat, synthetic_incoming(request, :noop)}
  end

  defp route_parsed_event(chat, %EventEnvelope{} = envelope, opts, _request) do
    with {:ok, updated_chat, routed_envelope} <- Jido.Chat.process_event(chat, :x, envelope, opts),
         %EventEnvelope{payload: %Incoming{} = incoming} <- routed_envelope do
      {:ok, updated_chat, incoming}
    else
      %EventEnvelope{} -> {:error, :unsupported_event_type}
      {:error, _reason} = error -> error
    end
  end

  defp synthetic_incoming(%WebhookRequest{} = request, event_type) do
    Incoming.new(%{
      external_room_id: "x",
      external_user_id: nil,
      external_message_id: WebhookRequest.header(request, "x-twitter-webhooks-delivery"),
      text: nil,
      raw: request.payload,
      metadata: %{event_type: event_type}
    })
  end

  defp event_envelope(event, %WebhookRequest{} = request) do
    with {:ok, incoming} <-
           transform_incoming(%{"dm_event" => event, "payload" => request.payload}) do
      {:ok,
       EventEnvelope.new(%{
         adapter_name: :x,
         event_type: :message,
         thread_id: thread_id(incoming.external_room_id),
         channel_id: to_string(incoming.external_room_id),
         message_id: to_string(incoming.external_message_id),
         payload: incoming,
         raw: request.payload,
         metadata: %{"for_user_id" => request.payload["for_user_id"]}
       })}
    end
  end

  defp incoming_from_dm(event, payload) do
    context = dm_context(event)
    source_payload = payload["payload"] || payload

    Incoming.new(%{
      external_room_id: "conversation:#{context.conversation_id || context.sender_id}",
      external_thread_id: context.conversation_id && to_string(context.conversation_id),
      external_message_id: context.id && to_string(context.id),
      external_user_id: context.sender_id && to_string(context.sender_id),
      text: context.text,
      timestamp: context.timestamp,
      author: author(context.sender_id),
      chat_type: :direct_message,
      raw: payload,
      media: media_from_event(event, source_payload),
      metadata: %{"conversation_id" => context.conversation_id}
    })
  end

  defp message_from_event(event, room_id, payload) do
    context = dm_context(event)

    Message.new(%{
      id: to_string(context.id || ID.generate!()),
      thread_id: thread_id(room_id),
      channel_id: to_string(room_id),
      text: context.text,
      raw: event,
      author: author(context.sender_id),
      attachments: media_from_event(event, payload),
      created_at: context.timestamp,
      external_message_id: context.id && to_string(context.id),
      external_room_id: room_id
    })
  end

  defp dm_context(event) do
    message_data = get_in(event, ["message_create", "message_data"]) || %{}

    %{
      id: event["id"] || event["dm_event_id"],
      conversation_id:
        event["dm_conversation_id"] || event["conversation_id"] ||
          get_in(event, ["dm_conversation", "id"]),
      sender_id: event["sender_id"] || get_in(event, ["message_create", "sender_id"]),
      text: event["text"] || message_data["text"] || "",
      timestamp: event["created_at"] || event["created_timestamp"]
    }
  end

  defp response_from_send(raw, room_id) do
    data = raw["data"] || raw[:data] || raw

    Response.new(%{
      external_message_id: data["dm_event_id"] || data[:dm_event_id] || data["id"],
      external_room_id:
        "conversation:#{data["dm_conversation_id"] || data[:dm_conversation_id] || room_id}",
      channel_type: :x,
      raw: raw
    })
  end

  defp put_response_metadata(%Response{} = response, key, value) do
    %{response | metadata: Map.put(response.metadata || %{}, key, value)}
  end

  defp dm_events(payload) do
    payload["direct_message_events"] || payload["dm_events"] || payload["data"] || []
  end

  defp media_from_event(event, payload) do
    direct_media(event) ++ included_media(event, payload)
  end

  defp direct_media(event) do
    event
    |> get_in(["message_create", "message_data", "attachment", "media"])
    |> case do
      %{} = media -> [media_from_x_media(media)]
      _ -> []
    end
  end

  defp included_media(event, payload) do
    media_by_key =
      payload
      |> get_in(["includes", "media"])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Map.new(fn media -> {media["media_key"] || media["id"], media} end)

    event
    |> get_in(["attachments", "media_keys"])
    |> List.wrap()
    |> Enum.flat_map(fn key ->
      case Map.get(media_by_key, key) do
        %{} = media -> [media_from_x_media(media)]
        _ -> []
      end
    end)
  end

  defp media_from_x_media(media) do
    Media.new(%{
      kind: media_kind(media["type"] || media["media_type"]),
      url: media["url"] || media["media_url_https"] || media["preview_image_url"],
      media_type: media["mime_type"],
      width: media["width"],
      height: media["height"],
      duration: media["duration_ms"],
      metadata: %{
        "id" => media["id"],
        "media_key" => media["media_key"],
        "raw" => media
      }
    })
  end

  defp media_kind(type) when type in ["photo", "animated_gif", "image"], do: :image
  defp media_kind(type) when type in ["video"], do: :video
  defp media_kind(type) when type in ["audio"], do: :audio
  defp media_kind(_type), do: :file

  defp format_crc_response(%WebhookRequest{} = request, secret, true) do
    cond do
      secret in [nil, ""] ->
        WebhookResponse.error(400, "missing_consumer_secret")

      crc_token(request) in [nil, ""] ->
        WebhookResponse.error(400, "missing_crc_token")

      true ->
        WebhookResponse.new(%{
          status: 200,
          body: %{"response_token" => "sha256=" <> hmac(secret, crc_token(request))}
        })
    end
  end

  defp format_crc_response(_request, _secret, false), do: WebhookResponse.accepted()

  defp valid_signature?(request, secret) do
    signature = WebhookRequest.header(request, "x-twitter-webhooks-signature")

    signature not in [nil, ""] and
      secure_compare(signature, "sha256=" <> hmac(secret, raw_body(request)))
  end

  defp consumer_secret(opts) do
    Keyword.get(opts, :consumer_secret) || System.get_env("X_CONSUMER_SECRET") ||
      System.get_env("SECRET_KEY")
  end

  defp get_request?(method), do: String.upcase(method || "POST") == "GET"

  defp conversation_room_id?(room_id),
    do: String.starts_with?(to_string(room_id), "conversation:")

  defp conversation_id(room_id),
    do: String.replace_prefix(to_string(room_id), "conversation:", "")

  defp filename_from_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> nil
      "" -> nil
      path -> path |> Path.basename() |> URI.decode()
    end
  rescue
    _ -> nil
  end

  defp filename_from_url(_url), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(value), do: to_string(value)

  defp author(nil), do: nil

  defp author(user_id),
    do: Author.new(%{user_id: to_string(user_id), user_name: to_string(user_id)})

  defp transport(opts), do: Keyword.get(opts, :transport, XdkClient)
  defp thread_id(room_id), do: "x:#{room_id}"
  defp crc_token(%WebhookRequest{query: query}), do: query["crc_token"] || query[:crc_token]
  defp raw_body(%WebhookRequest{raw: raw}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{metadata: %{"raw_body" => raw}}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{metadata: %{raw_body: raw}}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{payload: payload}), do: Jason.encode!(payload)
  defp hmac(secret, data), do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode64()
  defp secure_compare(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_compare(_, _), do: false
end
