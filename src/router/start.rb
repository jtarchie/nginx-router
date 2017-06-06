#!/usr/bin/env ruby

require 'digest/md5'
require 'erb'
require 'json'
require 'nats/io/client'
require 'resolv-replace'
require 'set'
require 'uri'

Endpoint = Struct.new(:host, :port, :uri)
Location = Struct.new(:path, :endpoints) do
  def upstream_name
    @upstream_name ||= "upstream_#{Digest::MD5.hexdigest self.inspect}"
  end

  def upstreams
    @upstream ||= begin
                    endpoints.map do |endpoint|
                      "#{endpoint.host}:#{endpoint.port}"
                    end
                  end
  end

  def path
    return '/' if self['path'] == ''
    self['path']
  end
end
HTTPRoute = Struct.new(:uri, :endpoints) do
  def locations
    @locations ||= endpoints.group_by do |endpoint|
      URI.parse("http://#{endpoint.uri}").path
    end.map do |path, endpoints|
      Location.new(path, endpoints)
    end
  end

  def host
    @host ||= URI.parse(uri).host
  end
end

def config
  @config ||= JSON.parse(File.read('/var/vcap/jobs/router/config/router.json'))
end

def nats_client
  @nats_client ||= begin
                     nats = NATS::IO::Client.new
                     nats.connect(
                       servers: config.dig('nats', 'machines').map do |ip|
                         "nats://#{config.dig('nats', 'user')}:#{config.dig('nats', 'password')}@#{ip}:#{config.dig('nats', 'port')}"
                       end,
                       reconnect_time_wait: 0.5,
                       max_reconnect_attempts: 2
                     )
                     nats
                   end
end

def endpoints
  @endpoints ||= Set.new
end

def endpoints_from_payload(reply)
  payload = JSON.parse(reply)
  payload['uris'].map do |uri|
    Endpoint.new(
      payload['host'],
      payload['port'],
      uri
    )
  end
end

def main
  puts "emitting confg for routes: #{endpoints.count}"
  File.write(
    '/var/vcap/run/nginx/ext/upstreams.conf',
    upstreams_template.result(binding)
  )
  File.write(
    '/var/vcap/run/nginx/ext/http_servers.conf',
    http_servers_template.result(binding)
  )
  system('kill -s HUP $(cat /var/vcap/run/nginx/nginx.pid)')
end

def http_routes
  results_by_route = endpoints.group_by { |e| e.uri }
  results_by_route.map do |uri, results|
    HTTPRoute.new("http://#{uri}", results)
  end
end

def upstreams_template
  @upstreams_template ||= ERB.new(<<-EOF, nil, '<>')
<% http_routes.each do |route| %>
# debug <%= route.inspect %>
<% route.locations.each do |location| %>
# debug: <%= location.inspect %>
upstream <%= location.upstream_name %> {
  <% location.upstreams.each do |upstream| %>
  server <%= upstream.to_s %>;
  <% end %>
}
<% end %>
<% end %>
EOF
end

def http_servers_template
  @http_servers_template ||= ERB.new(<<-EOF, nil, '<>')
<% http_routes.each do |route| %>
server {
  include /var/vcap/jobs/nginx/config/http.conf;
  server_name <%= route.host %>;

  <% route.locations.each do |location| %>
  location <%= location.path %> {
    proxy_pass http://<%= location.upstream_name %>;
  }
  <% end %>
}
<% end %>
EOF
end

def start_message
  puts 'sending router.start'
  nats_client.publish('router.start', {
    id: config.dig('spec', 'id'),
    hosts: [ config.dig('spec', 'address') ],
    minimumRegisterIntervalInSeconds: 20,
    prunteThresholdInSeconds: 120,
  }.to_json)
end

nats_client.subscribe('router.greet') do
  puts 'accepting router.greet'
  start_message
end

nats_client.subscribe('router.*') do |msg, reply, subject|
  case subject
  when 'router.register'
    endpoints.merge(endpoints_from_payload(msg))
  when 'router.unregister'
    endpoints.subtract(endpoints_from_payload(msg))
  end
end

start_message
if __FILE__ == $0
  puts 'Starting main loop'
  loop do
    main
    sleep 10
  end
end
