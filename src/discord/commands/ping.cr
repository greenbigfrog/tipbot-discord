class Ping
  def call(payload, ctx)
    client = ctx[Discord::Client]
    latency = Discord::EmbedField.new("Latency", "#{(Time.utc - payload.timestamp).total_milliseconds} ms", true)
    processing_time = Discord::EmbedField.new("Processed in", elapsed_text(Time.utc - ctx[Command].time), true)
    m = client.create_message(payload.channel_id, "Pong!", Discord::Embed.new(fields: [latency, processing_time]))
    return unless m.is_a?(Discord::Message)
    roundtrip = Discord::EmbedField.new("Roundtrip", "#{(Time.utc - payload.timestamp).total_milliseconds} ms", true)
    footer = Discord::EmbedFooter.new("Processing of the whole command took #{(Time.utc - ctx[Command].time).total_milliseconds} ms")
    client.edit_message(m.channel_id, m.id,
      "Pong!",
      Discord::Embed.new(footer: footer,
        fields: [latency, processing_time, roundtrip]))
    yield
  end

  private def elapsed_text(elapsed)
    millis = elapsed.total_milliseconds
    return "#{millis.round(2)}ms" if millis >= 1

    "#{(millis * 1000).round(2)}µs"
  end
end
