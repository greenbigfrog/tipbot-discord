class Balance
  def initialize(@coin : TB::Data::Coin)
  end

  def call(msg, ctx)
    str = "#{msg.author.username} has a confirmed balance of **#{TB::Data::Account.read(:discord, msg.author.id.to_u64.to_i64).balance(@coin)} #{@coin.name_short}**"
    str += "\n\nPlease pay attention to this important message:\n```tex\n$ #{@coin.balance_broadcast}```" if @coin.balance_broadcast
    ctx[Discord::Client].create_message(msg.channel_id, str)
    yield
  end
end
