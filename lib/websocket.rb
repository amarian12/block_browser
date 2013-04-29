require 'eventmachine'
require 'json'
require 'em-websocket'
require 'ostruct'

include ActionView::Helpers::NumberHelper
include ApplicationHelper
include Rails.application.routes.url_helpers

def compile_block_haml(block)
  ctx = OpenStruct.new(:blk => block)
  template = File.read(File.join(Rails.root, "app/views/blocks/_blk.html.haml"))
  res = Haml::Engine.new(template).render(ctx)
  "<tr>#{res.gsub!("\n", '')}</tr>"
end

EM.run do
  ws_host, ws_port = BB_CONFIG["websocket"].split(":")
  bc_host, bc_port = BB_CONFIG["command"].split(":")

  CHANNEL = EM::Channel.new
  CLIENTS = {}

  Bitcoin::Network::CommandClient.connect(bc_host, bc_port) do
    on_connected { request("monitor", "block") }
    on_block do |blk|
      block = STORE.get_block(blk['hash'])
      puts "new block: #{block.hash}"
      CHANNEL.push ["new_block", {depth: block.depth, json: block.to_hash,
                      partial: compile_block_haml(block)}]
      # TODO: fix caching properly
      cache_dir = File.join(Rails.root, "tmp/cache/")
      FileUtils.rm_rf cache_dir
      FileUtils.mkdir cache_dir
    end
  end

  EventMachine::WebSocket.start(:host => ws_host, :port => ws_port) do |ws|
    sid = nil
    ws.onopen do
      port, host = *Socket.unpack_sockaddr_in(ws.get_peername)
      puts "websocket client connected: #{host}:#{port}"
      sid = CHANNEL.subscribe {|msg| ws.send msg.to_json }
      CLIENTS[sid] = [host, port]
      CHANNEL.push ["client_count", CLIENTS.size]
    end
    ws.onclose do
      puts "websocket client disconnected"#: #{host}:#{port}"
      CHANNEL.unsubscribe(sid)
      CLIENTS.delete(sid)
      CHANNEL.push ["client_count", CLIENTS.size]
    end
  end

  puts "websocket listening on #{ws_host}:#{ws_port}"
end
