class Prefix
  include DiscordMiddleware::CachedRoutes

  def initialize
  end

  def call(msg, ctx)
    client = ctx[Discord::Client]

    client.create_message(msg.channel_id, "Current prefix is `#{ctx[ConfigMiddleware].get_prefix(msg)}`")

    yield
  end
end
