class Prefix
  include DiscordMiddleware::CachedRoutes

  def initialize
  end

  def call(msg, ctx)
    client = ctx[Discord::Client]

    str = <<-STR
    Current prefix is `#{ctx[ConfigMiddleware].get_prefix(msg)}`
    Any member with the ADMINISTRATOR permission can update the prefix at https://cryptobutler.info/configuration/guild?id=#{ctx[ConfigMiddleware].guild_id(msg)}
    STR

    client.create_message(msg.channel_id, str)

    yield
  end
end
