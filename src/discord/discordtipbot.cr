require "raven"
require "logger"
require "discordcr"
require "big"
require "big/json"
require "discordcr-middleware"
require "mosquito"

require "tb"

require "./**"

class DiscordTipBot
  def self.run
    log = Logger.new(STDOUT)

    Raven.configure do |raven_config|
      raven_config.async = true
    end

    Raven.capture do
      # Set your log level here
      log.level = Logger::DEBUG

      log.debug("Tipbot network getting started")

      shared_cache = Discord::Cache.new(Discord::Client.new(""))

      log.debug("starting forking")

      TB::Data::Coin.read.each do |coin|
        raven_spawn(name: "#{coin.name_short} Bot") do
          token = coin.discord_token
          raise "Missing Discord Token" unless token
          bot = Discord::Client.new(token, zlib_buffer_size: 10 * 1024 * 1024 * 2)
          cache = Discord::Cache.new(bot)
          shared_cache.bind(cache)
          bot.cache = cache

          DiscordBot.new(coin, bot, cache, log).run
        end
      end
      log.debug("finished forking")

      # spawn do
      #   server = HTTP::Server.new([Crometheus.default_registry.get_handler])
      #   server.bind_tcp "0.0.0.0", 5000
      #   server.listen
      # end

      log.info("All bots should be running now")
    end
    sleep
  end
end
