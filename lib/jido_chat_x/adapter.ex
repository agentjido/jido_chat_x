defmodule Jido.Chat.X.Adapter do
  @moduledoc "X/Twitter Direct Messages `Jido.Chat.Adapter` implementation."
  use Jido.Chat.Adapter

  alias Jido.Chat.Delivery
  alias Jido.Chat.Errors.Contract
  alias Jido.Chat.Signal.Identity
  alias Jido.Chat.Signal.Policy

  alias Jido.Chat.{
    Attachment,
    Author,
    FileUpload,
    ID,
    Media,
    Message,
    MessagePage,
    PostPayload,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.X.Transport.XdkClient
  @media_type_pattern ~r/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/
  @image_media_types %{
    ".avif" => "image/avif",
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }
  @impl true
  def channel_type do
    :x
  end

  @impl true
  def capabilities do
    %{
      send_message: :native,
      delete_message: :native,
      fetch_messages: :native,
      webhook: :native,
      verify_webhook: :native,
      normalize_event: :native,
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
      messages = events |> List.wrap() |> Enum.map(&message_from_event(&1, room_id, raw))

      {:ok,
       MessagePage.new(%{
         messages: messages,
         next_cursor: get_in(raw, ["meta", "next_token"]),
         metadata: %{"raw" => raw}
       })}
    end
  end

  @impl true
  def open_dm(user_id, _opts \\ []) do
    {:ok, to_string(user_id)}
  end

  @impl true
  def verify_webhook(request, opts \\ [])

  def verify_webhook(%WebhookRequest{method: method} = request, opts) do
    secret = consumer_secret(opts)

    cond do
      secret in [nil, ""] -> {:error, :missing_consumer_secret}
      get_request?(method) and crc_token(request) not in [nil, ""] -> :ok
      get_request?(method) -> {:error, :missing_crc_token}
      valid_signature?(request, secret) -> :ok
      true -> {:error, :invalid_signature}
    end
  end

  def verify_webhook(request, opts) when is_map(request) do
    request |> WebhookRequest.new() |> verify_webhook(opts)
  end

  @impl true
  def format_webhook_response(%WebhookRequest{method: method} = request, opts)
      when is_binary(method) do
    if get_request?(method),
      do: format_crc_response(request, consumer_secret(opts), true),
      else: WebhookResponse.error(400, "unsupported_control_method")
  end

  def format_webhook_response({:ok, %Delivery{}}, _opts) do
    WebhookResponse.accepted()
  end

  def format_webhook_response({:error, %Contract{code: code}}, _opts) do
    WebhookResponse.error(400, %{error: to_string(code)})
  end

  def format_webhook_response(_, _opts) do
    WebhookResponse.error(400, %{error: "rejected"})
  end

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
      [reply_context(opts), blank_to_nil(base) | attachment_lines] |> render_text_sections()
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

  defp attachment_line(%Attachment{}) do
    {:error, {:unsupported_file_upload, :x_requires_media_upload_or_remote_url}}
  end

  defp reply_context(opts) do
    case Keyword.get(opts, :reply_to_id) || Keyword.get(opts, :quote_id) do
      message_id when message_id in [nil, ""] -> nil
      message_id -> "Replying to #{message_id}:"
    end
  end

  defp render_text_sections(sections) do
    body = sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n") |> String.trim()

    if body == "" do
      {:error, :empty_message}
    else
      {:ok, body}
    end
  end

  defp incoming_from_dm(event, payload) do
    context = dm_context(event)
    source_payload = payload["payload"] || payload

    %{
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
    }
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

    %{
      external_message_id: data["dm_event_id"] || data[:dm_event_id] || data["id"],
      external_room_id:
        "conversation:#{data["dm_conversation_id"] || data[:dm_conversation_id] || room_id}",
      channel_type: :x,
      raw: raw
    }
  end

  defp put_response_metadata(%{} = response, key, value) do
    Map.put(response, :metadata, Map.put(Map.get(response, :metadata, %{}), key, value))
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
    kind = media_kind(media["type"] || media["media_type"])
    primary_url = first_non_blank([media["url"], media["media_url_https"]])
    url = first_non_blank([primary_url, media["preview_image_url"]])

    Media.new(%{
      kind: kind,
      url: url,
      media_type:
        normalize_media_type(media["mime_type"]) || media_type_from_primary_url(kind, primary_url),
      width: media["width"],
      height: media["height"],
      duration: media["duration_ms"],
      metadata: %{"id" => media["id"], "media_key" => media["media_key"], "raw" => media}
    })
  end

  defp media_kind(type) when type in ["photo", "animated_gif", "image"] do
    :image
  end

  defp media_kind(type) when type in ["video"] do
    :video
  end

  defp media_kind(type) when type in ["audio"] do
    :audio
  end

  defp media_kind(_type) do
    :file
  end

  defp media_type_from_primary_url(:image, url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      path when is_binary(path) -> path |> Path.extname() |> String.downcase()
      _other -> ""
    end
    |> then(&Map.get(@image_media_types, &1))
  end

  defp media_type_from_primary_url(_kind, _url) do
    nil
  end

  defp normalize_media_type(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@media_type_pattern, canonical_media_type(trimmed)) do
      trimmed
    else
      nil
    end
  end

  defp normalize_media_type(_value) do
    nil
  end

  defp canonical_media_type(value) do
    value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp first_non_blank(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        if String.trim(value) == "" do
          nil
        else
          value
        end

      _other ->
        nil
    end)
  end

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

  defp valid_signature?(request, secret) do
    signature = WebhookRequest.header(request, "x-twitter-webhooks-signature")

    signature not in [nil, ""] and
      secure_compare(signature, "sha256=" <> hmac(secret, raw_body(request)))
  end

  defp consumer_secret(opts) do
    if Keyword.has_key?(opts, :consumer_secret) do
      opts[:consumer_secret]
    else
      System.get_env("X_CONSUMER_SECRET") || System.get_env("SECRET_KEY")
    end
  end

  defp get_request?(method) do
    String.upcase(method || "POST") == "GET"
  end

  defp conversation_room_id?(room_id) do
    String.starts_with?(to_string(room_id), "conversation:")
  end

  defp conversation_id(room_id) do
    String.replace_prefix(to_string(room_id), "conversation:", "")
  end

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

  defp blank_to_nil(nil) do
    nil
  end

  defp blank_to_nil("") do
    nil
  end

  defp blank_to_nil(value) when is_binary(value) do
    value
  end

  defp blank_to_nil(value) do
    to_string(value)
  end

  defp author(nil) do
    nil
  end

  defp author(user_id) do
    Author.new(%{user_id: to_string(user_id), user_name: to_string(user_id)})
  end

  defp transport(opts) do
    Keyword.get(opts, :transport, XdkClient)
  end

  defp thread_id(room_id) do
    "x:#{room_id}"
  end

  defp crc_token(%WebhookRequest{query: query}) do
    query["crc_token"] || query[:crc_token]
  end

  defp raw_body(%WebhookRequest{raw: raw}) when is_binary(raw) do
    raw
  end

  defp raw_body(%WebhookRequest{metadata: %{"raw_body" => raw}}) when is_binary(raw) do
    raw
  end

  defp raw_body(%WebhookRequest{metadata: %{raw_body: raw}}) when is_binary(raw) do
    raw
  end

  defp raw_body(%WebhookRequest{payload: payload}) do
    Jason.encode!(payload)
  end

  defp hmac(secret, data) do
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode64()
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _) do
    false
  end

  @impl true
  def signal_protocol do
    1
  end

  @impl true
  def normalize_event(binding, input) do
    tracker = {__MODULE__, make_ref()}
    Process.put(tracker, [])

    result =
      try do
        with {:ok, items} <- native_inputs(binding, input) do
          delivery = "x:delivery:" <> native_digest({binding.id, Enum.map(items, &elem(&1, 2))})
          base = %{binding: binding, delivery: delivery, tracker: tracker}

          with {:ok, facts} <- native_items(base, items) do
            Delivery.new(binding, delivery, facts)
          end
        end
      rescue
        _ -> Policy.error(:invalid_delivery)
      catch
        _, _ -> Policy.error(:invalid_delivery)
      end

    if match?({:error, _}, result) do
      Enum.each(Process.get(tracker, []), &Jido.Chat.cancel_resource(binding, &1))
    end

    Process.delete(tracker)
    result
  end

  defp native_items(base, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{kind, payload, key}, index}, {:ok, acc} ->
      context = Map.merge(base, %{item: "x:item:" <> key, index: index})
      native_step(context, kind, payload, acc)
    end)
  end

  defp native_step(context, kind, payload, acc) do
    existing = Process.get(context.tracker)

    result =
      try do
        native_map(context, kind, payload)
      rescue
        _ -> {:error, :invalid_item}
      catch
        _, _ -> {:error, :invalid_item}
      end

    case result do
      {:ok, facts} ->
        facts = List.wrap(facts)

        if Enum.all?(facts, &(&1.type == "jido.chat.normalization.failed")) do
          Enum.each(
            Process.get(context.tracker) -- existing,
            &Jido.Chat.cancel_resource(context.binding, &1)
          )
        end

        {:cont, {:ok, acc ++ facts}}

      {:error, %Contract{code: code}} = error
      when code in [
             :signal_too_large,
             :delivery_too_large,
             :too_many_signals,
             :too_many_failures
           ] ->
        {:halt, error}

      _ ->
        Enum.each(
          Process.get(context.tracker) -- existing,
          &Jido.Chat.cancel_resource(context.binding, &1)
        )

        case native_failure(context, "invalid_item", kind, nil) do
          {:ok, fact} -> {:cont, {:ok, acc ++ [fact]}}
          error -> {:halt, error}
        end
    end
  end

  defp native_fact(context, definition, data, ordinal \\ "0") do
    room = data["room_id"]

    data =
      data
      |> Map.merge(%{
        "item_id" => context.item <> ":" <> definition.type() <> ":" <> ordinal,
        "delivery_id" => context.delivery
      })
      |> Map.reject(fn {key, value} ->
        is_nil(value) and key not in ["text", "previous", "current", "actor_id", "reaction"]
      end)

    subject =
      if is_binary(room) and room != "" do
        Identity.conversation_subject(context.binding.id, room)
      end

    definition.new(data, source: context.binding.source, subject: subject)
  end

  defp native_failure(context, code, kind, room) do
    native_fact(context, Jido.Chat.Signal.NormalizationFailed, %{
      "code" => code,
      "provider_kind" => kind,
      "item_index" => context.index,
      "room_id" => room
    })
  end

  defp native_media(context, media) do
    Enum.reduce_while(media, {:ok, []}, fn value, {:ok, acc} ->
      case Jido.Chat.put_resource(context.binding, "media", value) do
        {:ok, ref} ->
          Process.put(context.tracker, [ref | Process.get(context.tracker)])

          item =
            %{"kind" => to_string(value.kind), "resource_ref" => ref}
            |> native_optional("name", value.filename)
            |> native_optional("media_type", value.media_type)

          {:cont, {:ok, acc ++ [item]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp native_get(map, key) when is_map(map) do
    atom =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, atom)
    end
  end

  defp native_get(_, _) do
    nil
  end

  defp native_id(map, key) do
    native_identifier(native_get(map, key))
  end

  defp native_identifier(value) when is_binary(value) and value != "" do
    value
  end

  defp native_identifier(value) when is_integer(value) do
    to_string(value)
  end

  defp native_identifier(_) do
    nil
  end

  defp native_optional(map, _, nil) do
    map
  end

  defp native_optional(map, key, value) do
    Map.put(map, key, value)
  end

  defp native_time(%DateTime{} = value) do
    DateTime.to_iso8601(value)
  end

  defp native_time(value) when is_binary(value) do
    value
  end

  defp native_time(_) do
    nil
  end

  defp native_canonical(%_{} = value) do
    value |> Map.from_struct() |> native_canonical()
  end

  defp native_canonical(value) when is_map(value) do
    value |> Enum.map(fn {k, v} -> {to_string(k), native_canonical(v)} end) |> Enum.sort()
  end

  defp native_canonical(value) when is_list(value) do
    Enum.map(value, &native_canonical/1)
  end

  defp native_canonical(value) do
    value
  end

  defp native_digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(native_canonical(value), [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  @impl true
  def configure_binding(opts) do
    {:ok,
     opts
     |> Keyword.put_new(:transport, XdkClient)
     |> Keyword.put_new(
       :consumer_secret,
       System.get_env("X_CONSUMER_SECRET") || System.get_env("SECRET_KEY")
     )}
  end

  defp native_inputs(binding, %WebhookRequest{} = request) do
    with :ok <- verify_webhook(request, binding.options), do: verified_inputs(binding, request)
  end

  defp native_inputs(binding, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case native_inputs(binding, item) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        error -> {:halt, error}
      end
    end)
  end

  defp native_inputs(_binding, %{} = payload) do
    events = native_events(payload)

    if is_list(events) do
      {:ok,
       Enum.map(events, fn event ->
         kind =
           native_get(event, "type") || native_get(event, "event_type") ||
             if native_id(event, "sender_id") do
               "MessageCreate"
             else
               "unknown"
             end

         key = native_id(event, "id") || native_id(event, "dm_event_id") || native_digest(event)
         {kind, {event, payload}, key}
       end)}
    else
      Policy.error(:invalid_delivery)
    end
  end

  defp native_inputs(_, other) do
    {:ok, [{"invalid", {other, %{}}, native_digest(other)}]}
  end

  defp verified_inputs(binding, request) do
    if get_request?(request.method) do
      {:ok, []}
    else
      case Jason.decode(raw_body(request)) do
        {:ok, %{} = payload} -> native_inputs(binding, payload)
        _ -> Policy.error(:invalid_delivery)
      end
    end
  end

  defp native_events(payload) do
    if Enum.any?(["direct_message_events", "dm_events", "data"], &Map.has_key?(payload, &1)),
      do: dm_events(payload),
      else: [payload["dm_event"] || payload]
  end

  defp native_map(context, kind, {event, payload})
       when kind in ["MessageCreate", "message_create"] do
    incoming = incoming_from_dm(event, payload)

    with {:ok, media} <- native_media(context, incoming.media) do
      native_fact(context, Jido.Chat.Signal.MessageReceived, %{
        "room_id" => incoming.external_room_id,
        "message_id" => incoming.external_message_id,
        "sender" => %{"id" => incoming.external_user_id},
        "text" => incoming.text,
        "thread_id" => incoming.external_thread_id,
        "media" => media,
        "timestamp" => native_time(incoming.timestamp),
        "conversation_kind" => "direct"
      })
    end
  end

  defp native_map(context, kind, _) do
    native_failure(context, "unsupported_item", kind, nil)
  end
end
