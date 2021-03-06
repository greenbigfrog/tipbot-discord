require "rate_limiter"

class MW::RateLimiter
  include DiscordMiddleware::CachedRoutes

  def initialize
    @limiter = ::RateLimiter(Discord::Snowflake).new
    @limiter.bucket(:intense, 1_u32, 10.seconds)
    @limiter.bucket(:guild, 2_u32, 1.seconds)
    @limiter.bucket(:user, 5_u32, 10.seconds)

    @intense = {"soak", "rain"}
  end

  private def reply(client, channel_id)
    client.create_message(channel_id, "This command has been ratelimited. Please wait before trying again.")
  end

  def call(payload, ctx)
    client = ctx[Discord::Client]

    if @limiter.rate_limited?(:user, payload.author.id)
      reply(client, payload.channel_id)
      return
    end

    intense = @intense.includes?(ctx[Command].name)

    if guild_id = get_channel(client, payload.channel_id).guild_id
      if intense
        if @limiter.rate_limited?(:intense, guild_id)
          reply(client, payload.channel_id)
          return
        end
      end
      if @limiter.rate_limited?(:guild, guild_id)
        reply(client, payload.channel_id)
        return
      end
    end

    yield
  end
end
