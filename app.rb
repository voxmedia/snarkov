# encoding: utf-8
require "sinatra"
require "json"
require "httparty"
require "date"
require "redis"
require "dotenv"
require "securerandom"
require "oauth"

configure do
  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true
  # Exclude messages that match this regex
  set :message_exclude_regex, /^(voxbot|tacobot|pkmn|cabot|cfbot|campfirebot|\/)/i
  # Respond to messages that match this
  set :reply_to_regex, /cfbot|campfirebot/i
  
  # Set up redis
  case settings.environment
  when :development
    uri = URI.parse(ENV["LOCAL_REDIS_URL"])
  when :production
    uri = URI.parse(ENV["REDISCLOUD_URL"])
  end
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

get "/" do
  "hi."
end

get "/markov" do
  if params[:token] == ENV["OUTGOING_WEBHOOK_TOKEN"]
    status 200
    headers "Access-Control-Allow-Origin" => "*"
    body build_markov
  else
    status 403
    body "Nope."
  end
end

post "/markov" do
  response = ""
  # Ignore if text is a cfbot command, or a bot response, or the outgoing integration token doesn't match
  puts params
  unless params[:text].nil? || params[:text].match(settings.message_exclude_regex) || params[:user_id] == "USLACKBOT" || params[:user_id] == "" || params[:token] != ENV["OUTGOING_WEBHOOK_TOKEN"]
    # Don't store the text if someone is intentionally invoking a reply, tho
    unless params[:text].match(settings.reply_to_regex)
      $redis.pipelined do
        store_markov(params[:text])
      end
    end
    if SecureRandom.random_number <= ENV["RESPONSE_CHANCE"].to_f || params[:text].match(settings.reply_to_regex)
      reply = build_markov
      response = json_response_for_slack(reply)
      tweet(reply) unless ENV["SEND_TWEETS"].nil? || ENV["SEND_TWEETS"].downcase == "false"
    end
  end
  
  status 200
  body response
end

def store_markov(text)
  # Horrible regex, this
  text = text.gsub(/<@([\w]+)>/){ |m| get_slack_username($1) }
             .gsub(/<#([\w]+)>/){ |m| get_channel_name($1) }
             .gsub(/:-?\(/, ":disappointed:").gsub(/:-?\)/, ":smiley:")
             .gsub(/[‘’]/,"\'")
             .gsub(/\W_|_\W|^_|_$/, " ")
             .gsub(/<.*?>|&lt;.*?&gt;|&lt;|&gt;|[\*`<>"\(\)“”•]/, "")
             .gsub(/\n+/, " ")
             .downcase
  # Split words into array
  words = text.split(/\s+/)
  # Ignore if phrase is less than 3 words
  unless words.size < 3
    puts "[LOG] Storing: #{text}"
    (words.size - 2).times do |i|
      # Join the first two words as the key
      key = words[i..i+1].join(" ")
      # And the third as a value
      value = words[i+2]
      $redis.sadd(key, value)
    end
  end
end

def build_markov
  phrase = []
  # Get a random key (i.e. random pair of words) from Redis
  key = $redis.randomkey

  unless key.nil? || key.empty?
    # Split the key into the two words and add them to the phrase array
    key = key.split(" ")
    first_word = key.first
    second_word = key.last
    phrase << first_word
    phrase << second_word

    # With these two words as a key, get a third word from Redis
    # until there are no more words
    while phrase.size <= ENV["MAX_WORDS"].to_i && new_word = get_next_word(first_word, second_word)
      # Add the new word to the array
      phrase << new_word
      # Set the second word and the new word as keys for the next iteration
      first_word, second_word = second_word, new_word
    end
  end
  phrase.join(" ").strip
end

def get_next_word(first_word, second_word)
  $redis.srandmember("#{first_word} #{second_word}")
end

def json_response_for_slack(reply)
  puts "[LOG] Replying: #{reply}"
  response = { text: reply, link_names: 1 }
  response[:username] = ENV["BOT_USERNAME"] unless ENV["BOT_USERNAME"].nil?
  response[:icon_emoji] = ENV["BOT_ICON"] unless ENV["BOT_ICON"].nil?
  response.to_json
end

def tweet(tweet_text)
  begin
    consumer = OAuth::Consumer.new(ENV["TWITTER_API_KEY"], ENV["TWITTER_API_SECRET"], { site: "http://api.twitter.com" })
    access_token = OAuth::AccessToken.new(consumer, ENV["TWITTER_TOKEN"], ENV["TWITTER_TOKEN_SECRET"])
    tweet_text = tweet_text[0..138] + "…" if tweet_text.size > 140
    response = access_token.post("https://api.twitter.com/1.1/statuses/update.json", { status: tweet_text })
    response_json = JSON.parse(response.body)
    puts "[LOG] Sent tweet: http://twitter.com/statuses/#{response_json["id"]}"
  rescue OAuth::Error
    nil
  end
end

def get_slack_username(slack_id)
  # Wait a second so we don't get rate limited
  sleep 1
  username = ""
  uri = "https://slack.com/api/users.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    user = response["members"].find { |u| u["id"] == slack_id }
    username = "@#{user["name"]}" unless user.nil?
  else
    puts "Error fetching username: #{response["error"]}" unless response["error"].nil?
  end
  username
end

def get_channel_id(channel_name)
  # Wait a second so we don't get rate limited
  sleep 1
  uri = "https://slack.com/api/channels.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    channel = response["channels"].find { |u| u["name"] == channel_name.gsub("#","") }
    channel_id = channel["id"] unless channel.nil?
  else
    puts "Error fetching channel id: #{response["error"]}" unless response["error"].nil?
    ""
  end
end

def get_channel_name(channel_id)
  # Wait a second so we don't get rate limited
  sleep 1
  uri = "https://slack.com/api/channels.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    channel = response["channels"].find { |u| u["id"] == channel_id }
    channel_name = "##{channel["name"]}" unless channel.nil?
  else
    puts "Error fetching channel name: #{response["error"]}" unless response["error"].nil?
    ""
  end
end

def import_history(channel_id, ts = nil)
  # Wait 1 second so we don"t get rate limited
  sleep 1
  uri = "https://slack.com/api/channels.history?token=#{ENV["API_TOKEN"]}&channel=#{channel_id}&count=1000"
  uri += "&latest=#{ts}" unless ts.nil?
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    # Find all messages that are plain messages (no subtype), are not hidden, are not from a bot (integrations, etc.) and are not cfbot commands
    messages = response["messages"].find_all{ |m| m["subtype"].nil? && m["hidden"] != true && m["bot_id"].nil? && !m["text"].match(settings.message_exclude_regex) && !m["text"].match(settings.reply_to_regex)  }
    puts "Importing #{messages.size} messages from #{DateTime.strptime(messages.first["ts"],"%s").strftime("%c")}" if messages.size > 0
    
    $redis.pipelined do
      messages.each do |m|
        store_markov(m["text"])
      end
    end
    
    # If there are more messages in the API call, make another call, starting with the timestamp of the last message
    if response["has_more"] && !response["messages"].last["ts"].nil?
      ts = response["messages"].last["ts"]
      import_history(channel_id, ts)
    end
  else
    puts "Error fetching channel history: #{response["error"]}" unless response["error"].nil?
  end
end
