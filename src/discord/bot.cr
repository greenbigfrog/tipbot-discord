require "./utilities"
require "discordcr-middleware/middleware/cached_routes"
require "discordcr-middleware/middleware/permissions"
require "bot_list"
require "tb"
require "tb-worker"

require "crometheus"

module Crometheus
  module Middleware
    class DiscordCollector
      Crometheus.alias EventCounter = Crometheus::Counter[:event]

      # Crometheus.alias LatencyHistogram = Crometheus::Histogram[:event]

      def initialize(@registry = Crometheus.default_registry)
        @events = EventCounter.new(
          :discord_events_total,
          "Total number of Discord WS Events received.",
          @registry)
        # @latency = LatencyHistogram.new(
        #   :discord_latency_seconds,
        #   "Latency of receiving WS event. (Requires accurate clock for meaningful values.)",
        #   @registry)
      end

      def call(event, _ctx)
        @events[event: event[0]].inc

        # @latency[event: event[0]].observe time_diff

        yield
      end
    end
  end
end

USER_REGEX     = /<@!?(?<id>\d+)>/
ZWS            = "​" # There is a zero width space stored here
CONFIG_COLUMNS = ["min_soak", "min_soak_total", "min_rain", "min_rain_total", "min_tip", "prefix",
                  "soak", "rain", "mention", "contacted"]

class DiscordBot
  include Utilities
  include TB::StringSplit

  def initialize(@coin : TB::Data::Coin, @bot : Discord::Client, @cache : Discord::Cache, @log : Logger)
    @log.debug("#{@coin.name_short}: starting bot: #{@coin.name_long}")
    @active_users_cache = ActivityCache.new(10.minutes)
    @presence_cache = PresenceCache.new
    @webhook = Discord::Client.new("")

    bot_id = @cache.resolve_current_user.id
    @prefix_regex = /^(?:#{Regex.escape(@coin.prefix)}|<@!?#{bot_id}> ?)(?<cmd>.*)/

    admin = DiscordMiddleware::Permissions.new(Discord::Permissions::Administrator, "**Permission Denied.** User must have %permissions%")
    rl = MW::RateLimiter.new
    error = ErrorCatcher.new
    config = ConfigMiddleware.new(@coin)
    typing = TriggerTyping.new
    bot_admin = BotAdmin.new(@coin)

    spawn do
      server = HTTP::Server.new([Crometheus.default_registry.get_handler])
      server.bind_tcp "0.0.0.0", 5000
      server.listen
    end
    @bot.on_dispatch(Crometheus::Middleware::DiscordCollector.new)

    @bot.on_message_create(error, config, Command.new("ping"),
      rl, Ping.new)
    @bot.on_message_create(error, config, Command.new("withdraw"),
      rl, Withdraw.new(@coin))
    @bot.on_message_create(error, config, Command.new(["deposit", "address"]),
      rl, Deposit.new(@coin))
    @bot.on_message_create(error, config, Command.new("soak"),
      rl, NoPrivate.new, typing, Soak.new(@coin, @cache, @presence_cache))
    @bot.on_message_create(error, config, Command.new("tip"),
      rl, NoPrivate.new, Tip.new(@coin))
    @bot.on_message_create(error, config, Command.new("donate"),
      rl, Donate.new(@coin, @webhook))
    @bot.on_message_create(error, config, Command.new(["balance", "bal"]),
      rl, Balance.new(@coin))
    @bot.on_message_create(error, config, Command.new("\u{1f4be}"),
      rl, SystemStats.new)
    # @bot.on_message_create(error, config, Command.new("offsite"),
    #   rl, OnlyPrivate.new, bot_admin, Offsite.new(@coin))
    # @bot.on_message_create(error, config, Command.new("admin"),
    #   rl, OnlyPrivate.new, bot_admin, Admin.new)
    @bot.on_message_create(error, config, Command.new(["checkconfig", "config"]),
      rl, CheckConfig.new)
    @bot.on_message_create(error, config, Command.new("prefix"),
      rl, NoPrivate.new, admin, Prefix.new)
    @bot.on_message_create(error, config, Command.new("vote"),
      rl, Vote.new)
    @bot.on_message_create(error, config, Command.new("lucky"),
      rl, NoPrivate.new) { |msg, ctx| lucky(msg, ctx) }
    @bot.on_message_create(error, config, Command.new("rain"),
      rl, NoPrivate.new) { |msg, ctx| rain(msg, ctx) }
    @bot.on_message_create(error, config, Command.new("active"),
      rl, NoPrivate.new) { |msg, _| active(msg) }
    @bot.on_message_create(error, config, Command.new("statistics"), rl) do |msg, _|
      stats = TB::Data::Statistics.read
      string = String.build do |io|
        io.puts "*Currently the users of this bot have:*"
        io.puts "Transfered a total of **#{stats.transaction_sum} #{@coin.name_short}** in #{stats.transaction_count} transactions"
        io.puts
        io.puts "Of these **#{stats.tip_sum} #{@coin.name_short}** were tips,"
        io.puts "**#{stats.rain_sum} #{@coin.name_short}** were rains and"
        io.puts "**#{stats.soak_sum} #{@coin.name_short}** were soaks."
        io.puts "*Last updated at #{stats.last_refresh}*"
      end

      reply(msg, string)
    end
    @bot.on_message_create(error, config,
      Command.new("exit"), rl, bot_admin) do |msg, _|
      @log.warn("#{@coin.name_short}: Shutdown requested by #{msg.author.id}")
      sleep 1
      exit
    end
    @bot.on_message_create(error, config,
      Command.new("stats"), rl) do |msg, _|
      guilds = @cache.guilds.size
      cached_users = @cache.users.size
      users = @cache.guilds.values.map { |x| x.member_count || 0 }.sum

      reply(msg, "The bot is in #{guilds} Guilds and sees #{users} users (of which #{cached_users} users are guaranteed unique)\n*(This is for all bots running in this process on this shard. TL;DR It's broken)*")
    end
    @bot.on_message_create(error, config,
      Command.new("getinfo"), rl, bot_admin, OnlyPrivate.new) do |msg, _|
      api = TB::CoinApi.new(@coin, Logger.new(STDOUT))
      info = api.get_info.as_h
      next unless info.is_a?(Hash(String, JSON::Any))

      embed = Array(Discord::EmbedField).new

      info.map do |key, val|
        embed << Discord::EmbedField.new(key, val.to_s, true) unless val.to_s.empty?
      end

      @bot.create_message(msg.channel_id, ZWS, Discord::Embed.new(fields: embed))
    end
    @bot.on_message_create(error, config,
      Command.new("help"), rl) do |msg, _|
      # TODO rewrite help command
      cmds = {"ping", "uptime", "tip", "soak", "rain", "active", "balance", "terms", "withdraw", "deposit", "support", "github", "invite"}
      string = String.build do |str|
        cmds.each { |x| str << "`" + @coin.prefix + x + "`, " }
      end

      string = string.rchop(", ")

      reply(msg, "Currently the following commands are available: #{string}")
    end

    @bot.on_message_create(error) do |msg|
      content = msg.content

      if private_channel?(msg)
        content = @coin.prefix + content unless content.match(@prefix_regex)
      end

      next unless match = content.match(@prefix_regex)
      next unless cmd = match.named_captures["cmd"]

      case cmd
      when .starts_with? "terms"
        reply(msg, TB::TERMS)
      when .starts_with? "status"
        reply(msg, "Visit <https://status.cryptobutler.info> for status information")
      when .starts_with? "support"
        reply(msg, "For support please visit <http://tipbot.gbf.re>")
      when .starts_with? "github"
        reply(msg, "To contribute to the development of the tipbot visit <https://github.com/greenbigfrog/tipbot-main>")
      when .starts_with? "invite"
        reply(msg, "You can add this bot to your own guild using following URL: <https://discordapp.com/oauth2/authorize?&client_id=#{@coin.discord_client_id}&scope=bot>")
      when .starts_with? "uptime"
        reply(msg, "Bot has been running for #{Time.now - TB::START_TIME}")
      end
    end

    @bot.on_ready(error) do
      @log.info("#{@coin.name_short}: #{@coin.name_long} bot received READY")

      # Make use of the status to display info
      raven_spawn do
        sleep 10
        Discord.every(1.minutes) do
          update_game("#{@coin.prefix}help | Serving #{@cache.users.size} users in #{@cache.guilds.size} guilds")
        end
      end
    end

    @bot.on_ready(error) do
      # Disable stats posting with `export STATS=sth`
      next if ENV["STATS"]?
      sleep 1.minute
      bot_list = BotList::Client.new(@bot)
      bot_list.add_provider(BotList::DBotsDotOrgProvider.new(@coin.dbl_stats)) if @coin.dbl_stats
      bot_list.add_provider(BotList::DBotsDotGGProvider.new(@coin.botsgg_token)) if @coin.botsgg_token

      bot_list.update_every(30.minutes)
    end

    # Add user to active_users_cache on new message unless bot user
    @bot.on_message_create(error) do |msg|
      next if msg.content.match @prefix_regex
      @active_users_cache.touch(msg.channel_id.to_u64, msg.author.id.to_u64, msg.timestamp.to_utc) unless msg.author.bot
    end

    # Check if it's time to send off (or on) site
    # raven_spawn do
    #   Discord.every(10.seconds) do
    #     check_and_notify_if_its_time_to_send_back_onsite
    #     check_and_notify_if_its_time_to_send_offsite
    #   end
    # end

    bot_icon_url = @bot.get_current_user.avatar_url
    @bot.on_guild_create(error) do |payload|
      id = payload.id.to_u64.to_i64
      if TB::Data::Discord::Guild.new?(id, @coin)
        TB::Worker::NewGuildJob.new(guild_id: id, coin: @coin.id, guild_name: payload.name, owner: payload.owner_id.to_u64.to_i64).enqueue

        owner = @cache.resolve_user(payload.owner_id)
        embed = Discord::Embed.new(
          title: payload.name,
          thumbnail: Discord::EmbedThumbnail.new("https://cdn.discordapp.com/icons/#{payload.id}/#{payload.icon}.png"),
          colour: 0x00ff00_u32,
          timestamp: Time.now,
          fields: [
            Discord::EmbedField.new(name: "Owner", value: "#{owner.username}##{owner.discriminator}; <@#{owner.id}>"),
            Discord::EmbedField.new(name: "Membercount", value: payload.member_count.to_s),
          ]
        )
        TB::Worker::WebhookJob.new(webhook_type: "general", embed: embed.to_json,
          avatar_url: bot_icon_url, username: @coin.name_long).enqueue
      end
    end

    @bot.on_guild_create(error) do |payload|
      @presence_cache.handle_presence(payload.presences)
    end

    @bot.on_presence_update(error) do |presence|
      @presence_cache.handle_presence(presence)

      @cache.cache(Discord::User.new(presence.user)) if presence.user.full?
    end

    # on launch check for deposits and insert them into coin_transactions during down time
    # raven_spawn do
    #   @tip.insert_history_deposits
    #   @log.info("#{@coin.name_short}: Inserted deposits during down time")
    # end

    # warn users that the tipbot shouldn't be used as wallet if their balance exceeds @coin.high_balance
    # raven_spawn do
    #   Discord.every(1.hours) do
    #     if Set{6, 18}.includes?(Time.now.hour)
    #       users = @tip.get_high_balance(@coin.high_balance)

    #       users.each do |x|
    #         @bot.create_message(@cache.resolve_dm_channel(x.to_u64), "Your balance exceeds #{@coin.high_balance} #{@coin.name_short}. You should consider withdrawing some coins! You should not use this bot as your wallet!")
    #       end
    #     end
    #   end
    # end

    # periodically clean up the user activity cache
    raven_spawn do
      Discord.every(60.minutes) do
        @active_users_cache.prune
      end
    end
  end

  # Since there is no easy way, just to reply to a message
  private def reply(payload : Discord::Message, msg : String)
    if msg.size > 2000
      msgs = split(msg)
      msgs.each { |x| @bot.create_message(payload.channel_id.to_u64, x) }
    else
      @bot.create_message(payload.channel_id.to_u64, msg)
    end
  rescue
    @log.warn("#{@coin.name_short}: bot failed sending a msg to #{payload.channel_id} with text: #{msg}")
  end

  private def update_game(name : String)
    @bot.status_update("online", Discord::GamePlaying.new(name, 0_i64))
  end

  private def dm_deposit(userid : UInt64)
    @bot.create_message(@cache.resolve_dm_channel(userid), "Your deposit just went through! Remember: Deposit Addresses are *one-time* use only so you'll have to generate a new address for your next deposit!\n*#{TB::TERMS}*")
  rescue ex
    user = @cache.resolve_user(userid)
    @log.warn("#{@coin.name_short}: Failed to contact #{userid} (#{user.username}##{user.discriminator}}) with deposit notification (Exception: #{ex.inspect_with_backtrace})")
  end

  private def private_channel?(msg : Discord::Message)
    channel(msg).type == Discord::ChannelType::DM
  end

  private def channel(msg : Discord::Message) : Discord::Channel
    @cache.resolve_channel(msg.channel_id)
  end

  private def guild_id(msg : Discord::Message)
    id = channel(msg).guild_id
    # If it's a DM channel, it won't have an Guild ID. Else it should.
    raise "Somehow we tried getting the Guild ID of a DM" unless id
    id.to_u64
  end

  private def trigger_typing(msg : Discord::Message)
    @bot.trigger_typing_indicator(msg.channel_id)
  end

  def run
    @bot.run
  end

  private def bot?(user : Discord::User)
    bot_status = user.bot
    if bot_status
      return false if @coin.whitelisted_bots.includes?(user.id)
    end
    bot_status
  end

  # private def check_and_notify_if_its_time_to_send_offsite
  #   wallet = @tip.node_balance(@coin.confirmations)
  #   users = @tip.db_balance
  #   return if wallet == 0 || users == 0
  #   goal_percentage = BigDecimal.new(0.25)

  #   if (wallet / users) > 0.4
  #     return if @tip.pending_withdrawal_sum > @tip.node_balance
  #     missing = wallet - (users * goal_percentage)
  #     return if @tip.pending_coin_transactions
  #     current_percentage = ((wallet / users) * 100).round(4)
  #     embed = Discord::Embed.new(
  #       title: "It's time to send some coins off site",
  #       description: "Please remove **#{missing} #{@coin.name_short}** from the bot and to your own wallet! `#{@coin.prefix}offsite send`",
  #       colour: 0x0066ff_u32,
  #       timestamp: Time.now,
  #       fields: offsite_fields(users, wallet, current_percentage, goal_percentage * 100)
  #     )
  #     TB::Worker::WebhookJob.new(webhook_type: "admin", embed: embed.to_json).enqueue
  #     wait_for_balance_change(wallet, Compare::Smaller)
  #   end
  # end

  # private def check_and_notify_if_its_time_to_send_back_onsite
  #   wallet = @tip.node_balance(0)
  #   users = @tip.db_balance
  #   return if wallet == 0 || users == 0
  #   goal_percentage = BigDecimal.new(0.35)

  #   if (wallet / users) < 0.2 || @tip.pending_withdrawal_sum > @tip.node_balance
  #     missing = wallet - (users * goal_percentage)
  #     missing = missing - @tip.pending_withdrawal_sum if @tip.pending_withdrawal_sum > @tip.node_balance
  #     current_percentage = ((wallet / users) * 100).round(4)
  #     embed = Discord::Embed.new(
  #       title: "It's time to send some coins back to the bot",
  #       description: "Please deposit **#{missing} #{@coin.name_short}** to the bot (your own `#{@coin.prefix}offsite address`)",
  #       colour: 0xff0066_u32,
  #       timestamp: Time.now,
  #       fields: offsite_fields(users, wallet, current_percentage, goal_percentage * 100)
  #     )
  #     TB::Worker::WebhookJob.new(webhook_type: "admin", embed: embed.to_json).enqueue
  #     wait_for_balance_change(wallet, Compare::Bigger)
  #   end
  # end

  # private def offsite_fields(user_balance : BigDecimal, wallet_balance : BigDecimal, current_percentage, goal_percentage)
  #   [
  #     Discord::EmbedField.new(name: "Current Total User Balance", value: "#{user_balance} #{@coin.name_short}"),
  #     Discord::EmbedField.new(name: "Current Wallet Balance", value: "#{wallet_balance} #{@coin.name_short}"),
  #     Discord::EmbedField.new(name: "Current Percentage", value: "#{current_percentage}%"),
  #     Discord::EmbedField.new(name: "Goal Percentage", value: "#{goal_percentage}%"),
  #   ]
  # end

  # private def wait_for_balance_change(old_balance : BigDecimal, compare : Compare)
  #   time = Time.now

  #   new_balance = 0

  #   loop do
  #     return if (Time.now - time) > 10.minutes
  #     new_balance = @tip.node_balance(0)
  #     break if new_balance > old_balance if compare.bigger?
  #     break if new_balance < old_balance if compare.smaller?
  #     sleep 1
  #   end

  #   embed = Discord::Embed.new(
  #     title: "Success",
  #     colour: 0x00ff00_u32,
  #     timestamp: Time.now,
  #     fields: [Discord::EmbedField.new(name: "New wallet balance", value: "#{new_balance} #{@coin.name_short}")]
  #   )
  #   TB::Worker::WebhookJob.new(webhook_type: "admin", embed: embed.to_json).enqueue
  # end
end
